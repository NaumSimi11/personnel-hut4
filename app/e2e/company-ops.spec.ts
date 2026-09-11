import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Company operations (plan 024): the overview lists upcoming starters and
 * departures, the Settings tab assigns workflow owners, a submitted hiring
 * request shows who it is waiting on, and the Access tab can invite.
 * Seeds a starter and a departing person at Praedium plus one request.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const STARTER = 'E2E Ops Starter'
const LEAVER = 'E2E Ops Leaver'
const REQUEST_TITLE = 'E2E Ops Analyst'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''
let leaverId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (company) {
    await db.from('workflow_owners').delete().eq('company_id', company.id).eq('role_key', 'hiring_approver')
    await db.from('hiring_requests').delete().eq('company_id', company.id).eq('title', REQUEST_TITLE)
  }
  const { data: people } = await db.from('people').select('id').in('full_name', [STARTER, LEAVER])
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
  const { data: starter } = await db.from('people').insert({ full_name: STARTER }).select('id').single()
  const { data: leaver } = await db.from('people').insert({ full_name: LEAVER }).select('id').single()
  leaverId = leaver!.id
  const { error } = await db.from('employment_periods').insert([
    { person_id: starter!.id, company_id: companyId, job_title: 'Junior Analyst', status: 'pre_start', start_date: '2030-02-01' },
    {
      person_id: leaverId,
      company_id: companyId,
      job_title: 'Senior Analyst',
      status: 'active',
      start_date: '2022-01-10',
      end_date: '2030-06-30',
      last_working_date: '2030-06-20',
    },
  ])
  if (error) throw new Error(`Could not seed periods: ${error.message}`)
  const { error: reqErr } = await db
    .from('hiring_requests')
    .insert({ company_id: companyId, title: REQUEST_TITLE, status: 'submitted', requested_by: null })
  if (reqErr) throw new Error(`Could not seed the request: ${reqErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('upcoming → workflow owner saved → request shows approver → invite from Access', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // Overview: upcoming starters and departures.
  await page.goto(`/companies/${companyId}`)
  const upcomingCard = page.locator('.card', { hasText: 'Upcoming' })
  const starterRow = upcomingCard.locator('.upcoming-row', { hasText: STARTER })
  await expect(starterRow).toContainText('starts 2030-02-01')
  const leaverRow = upcomingCard.locator('.upcoming-row', { hasText: LEAVER })
  await expect(leaverRow).toContainText('leaves 2030-06-30')
  await expect(leaverRow).toContainText('last day 2030-06-20')

  // Before an owner is configured the request says so.
  await page.goto('/hiring')
  const request = page.locator('.request-row', { hasText: REQUEST_TITLE })
  await expect(request).toContainText('no approver configured')

  // Settings: assign the hiring approver.
  await page.goto(`/companies/${companyId}?tab=settings`)
  await page.getByRole('tab', { name: 'Settings' }).click()
  const ownerRow = page.locator('.owner-row', { hasText: 'Approves hiring requests' })
  await ownerRow.locator('select').selectOption({ label: LEAVER })
  await ownerRow.getByRole('button', { name: 'Save' }).click()
  await expect(ownerRow).toContainText('Saved')
  const { data: owner } = await db
    .from('workflow_owners')
    .select('person_id')
    .eq('company_id', companyId)
    .eq('role_key', 'hiring_approver')
    .single()
  expect(owner?.person_id).toBe(leaverId)

  // The request now names who it waits on.
  await page.goto('/hiring')
  await expect(page.locator('.request-row', { hasText: REQUEST_TITLE })).toContainText(`Awaiting ${LEAVER}`)

  // Access tab: invite opens the dialog.
  await page.goto(`/companies/${companyId}?tab=access`)
  await page.getByRole('tab', { name: 'Access' }).click()
  await page.getByRole('button', { name: 'Invite person' }).click()
  await expect(page.getByRole('dialog')).toBeVisible()
  await expect(page.getByRole('dialog').locator('#invite-email')).toBeVisible()
})
