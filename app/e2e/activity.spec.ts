import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Activity history (plan 030): an employment change made in the UI shows
 * on the company's Activity tab with the actor and the changed field; the
 * entity filter narrows the list. Seeds one person at Praedium.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Activity Subject'
const NEW_TITLE = `Audit Lead ${Date.now().toString(36)}`

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
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    const { data: periods } = await db.from('employment_periods').select('id').in('person_id', ids)
    const periodIds = (periods ?? []).map((p) => p.id)
    if (periodIds.length) await db.from('employment_changes').delete().in('employment_period_id', periodIds)
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
    .insert({ person_id: personId, company_id: companyId, job_title: 'Auditor', status: 'active', start_date: '2024-06-01' })
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

test('an employment change appears on the Activity tab with actor and changed field; filter narrows', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto(`/people/${personId}`)
  await page.locator('.emp-row', { hasText: 'Auditor · Praedium' }).getByRole('button', { name: 'Schedule change' }).click()
  const dialog = page.getByRole('dialog')
  await dialog.locator('#chg-title').fill(NEW_TITLE)
  await dialog.getByRole('button', { name: 'Save change' }).click()
  await expect(page.getByText('Change applied')).toBeVisible()

  await page.goto(`/companies/${companyId}?tab=activity`)
  await page.getByRole('tab', { name: 'Activity' }).click()
  const activity = page.locator('.card', { hasText: 'Activity' })
  const row = activity.locator('.activity-row', { hasText: NEW_TITLE }).first()
  await expect(row).toContainText('Employment')
  await expect(row).toContainText('updated')
  await expect(row).toContainText(`Job title: Auditor → ${NEW_TITLE}`)
  await expect(row.locator('.actor')).not.toHaveText('system')

  // Filter to the change record itself: its summary never carries the title.
  await activity.locator('#activity-entity').selectOption('employment_changes')
  await expect(activity.locator('.activity-row', { hasText: NEW_TITLE })).toHaveCount(0)
  await activity.locator('#activity-entity').selectOption('employment_periods')
  await expect(activity.locator('.activity-row', { hasText: NEW_TITLE }).first()).toBeVisible()
})
