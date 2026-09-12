import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Equipment & IT (plan 029): register an asset on the company's Equipment
 * tab, reserve it for a person, issue it, see it on the profile, return it
 * damaged; raise an IT request and work it to done.
 * Seeds one person at Praedium.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Equipment Holder'
const TAG = `E2E-LT-${Date.now().toString(36).toUpperCase()}`
const REQUEST_TITLE = 'E2E Laptop and VPN setup'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''
let personId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (company) {
    const { data: assets } = await db.from('assets').select('id').eq('company_id', company.id).like('asset_tag', 'E2E-LT-%')
    const ids = (assets ?? []).map((a) => a.id)
    if (ids.length) {
      await db.from('asset_assignments').delete().in('asset_id', ids)
      await db.from('assets').delete().in('id', ids)
    }
    await db.from('it_requests').delete().eq('company_id', company.id).eq('title', REQUEST_TITLE)
  }
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    await db.from('employment_periods').delete().in('person_id', ids)
    await db.from('people').delete().in('id', ids)
  }
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id
  const { data: person } = await db.from('people').insert({ full_name: PERSON }).select('id').single()
  personId = person!.id
  const { error } = await db
    .from('employment_periods')
    .insert({ person_id: personId, company_id: companyId, job_title: 'Engineer', status: 'active', start_date: '2024-04-01' })
  if (error) throw new Error(`Could not seed the period: ${error.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('asset → reserve → issue → on profile → return damaged; IT request → in progress → done', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto(`/companies/${companyId}?tab=equipment`)
  await page.getByRole('tab', { name: 'Equipment' }).click()
  const assets = page.locator('.card', { hasText: 'Assets' })
  await assets.getByRole('button', { name: 'Add asset' }).click()
  await assets.locator('#asset-tag').fill(TAG.toLowerCase())
  await assets.locator('#asset-type').selectOption('laptop')
  await assets.locator('#asset-model').fill('ThinkPad T14')
  await assets.getByRole('button', { name: 'Save asset' }).click()
  const row = assets.locator('.asset-row', { hasText: TAG })
  await expect(row).toContainText('Available')

  // Reserve for the person, then issue.
  await row.getByRole('button', { name: 'Reserve' }).click()
  await assets.locator('#reserve-person').selectOption({ label: PERSON })
  await assets.getByRole('button', { name: 'Confirm reservation' }).click()
  await expect(row).toContainText('Reserved')
  await expect(row).toContainText(PERSON)
  await row.getByRole('button', { name: 'Issue' }).click()
  await expect(row).toContainText('Assigned')

  // Visible on the person's profile.
  await page.goto(`/people/${personId}`)
  const held = page.locator('.card', { hasText: 'Equipment' })
  await expect(held.locator('.equipment-row', { hasText: TAG })).toContainText('ThinkPad T14')
  await expect(held.locator('.equipment-row', { hasText: TAG })).toContainText('issued')

  // Return it damaged.
  await page.goto(`/companies/${companyId}?tab=equipment`)
  await page.getByRole('tab', { name: 'Equipment' }).click()
  await row.getByRole('button', { name: 'Return' }).click()
  await assets.locator('#return-condition').fill('Cracked screen')
  await assets.locator('#return-status').selectOption('damaged')
  await assets.getByRole('button', { name: 'Confirm return' }).click()
  await expect(row).toContainText('Damaged')
  const { data: asset } = await db.from('assets').select('status, condition, asset_assignments(returned_at, return_condition)').eq('asset_tag', TAG).single()
  expect(asset?.status).toBe('damaged')
  expect(asset?.condition).toBe('Cracked screen')
  expect(asset?.asset_assignments?.[0]?.returned_at).not.toBeNull()

  // IT request lifecycle.
  const requests = page.locator('.card', { hasText: 'IT requests' })
  await requests.getByRole('button', { name: 'New request' }).click()
  await requests.locator('#it-person').selectOption({ label: PERSON })
  await requests.locator('#it-title').fill(REQUEST_TITLE)
  await requests.locator('#it-systems').fill('email, vpn')
  await requests.getByRole('button', { name: 'Create request' }).click()
  const requestRow = requests.locator('.request-row', { hasText: REQUEST_TITLE })
  await expect(requestRow).toContainText('Open')
  await expect(requestRow).toContainText('email, vpn')
  await requestRow.getByRole('button', { name: 'Start' }).click()
  await expect(requestRow).toContainText('In progress')
  await requestRow.getByRole('button', { name: 'Done' }).click()
  await expect(requestRow).toContainText('Done')
  const { data: request } = await db.from('it_requests').select('status, assignee_id').eq('title', REQUEST_TITLE).single()
  expect(request?.status).toBe('done')
  expect(request?.assignee_id).not.toBeNull()
})
