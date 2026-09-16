import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Employee records foundation: add a person (record only, no account), see
 * them in the directory with employment, walk their profile, end the
 * employment. Cleans up with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON_NAME = 'E2E Employee Record'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function removeTestPerson(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON_NAME)
  for (const person of people ?? []) {
    // Scheduling a departure adds a plan with tasks and restricted details.
    const { data: plans } = await db.from('plans').select('id').eq('person_id', person.id)
    const planIds = (plans ?? []).map((p) => p.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', person.id)
    const { data: periods } = await db.from('employment_periods').select('id').eq('person_id', person.id)
    const periodIds = (periods ?? []).map((p) => p.id)
    if (periodIds.length) {
      await db.from('employment_departure_details').delete().in('employment_period_id', periodIds)
    }
    await db.from('employment_periods').delete().eq('person_id', person.id)
    await db.from('people').delete().eq('id', person.id)
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await removeTestPerson()
})

test.afterAll(async () => {
  await removeTestPerson()
})

test('add person → directory → profile → end employment', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.getByRole('link', { name: 'People & access', exact: true }).click()

  // Create the record with its first employment at Praedium.
  await page.getByRole('button', { name: 'Add employee' }).click()
  const add = page.getByTestId('add-employee-dialog')
  await add.locator('#ae-name').fill(PERSON_NAME)
  await add.locator('#ae-company').selectOption({ label: 'Praedium' })
  await add.locator('#ae-title').fill('Warehouse Lead')
  await add.getByRole('button', { name: 'Create employee' }).click()
  await expect(add.getByRole('heading', { name: /Added\. Employment recorded, the onboarding checklist started/ })).toBeVisible()
  await add.getByRole('button', { name: 'Done' }).click()

  // Directory shows employment context; record-only people have no account.
  const row = page.locator('tr', { hasText: PERSON_NAME })
  await expect(row).toBeVisible()
  await expect(row).toContainText('Praedium')
  await expect(row).toContainText('Warehouse Lead')
  await expect(row.locator('.badge')).toHaveText('active')

  // Profile: identity, account state, employment history.
  await row.getByRole('link', { name: PERSON_NAME }).click()
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  await expect(page.getByText('no account — record only')).toBeVisible()
  const empRow = page.locator('.emp-row', { hasText: 'Warehouse Lead · Praedium' })
  await expect(empRow).toBeVisible()
  await expect(empRow.locator('.badge')).toHaveText('active')

  // Departure is a workflow (plan 016): schedule first, then the explicit
  // act of becoming former. History stays; the row shows both dates.
  await empRow.getByRole('button', { name: 'Schedule departure' }).click()
  const dialog = page.getByRole('dialog')
  const endDate = new Date(Date.now() + 14 * 86400000).toISOString().slice(0, 10)
  await dialog.locator('#dep-end').fill(endDate)
  await dialog.getByRole('button', { name: 'Schedule departure' }).click()
  await expect(empRow).toContainText(`Departing · last day ${endDate}`)
  await expect(empRow.locator('.badge', { hasText: 'active' })).toBeVisible()

  await empRow.getByRole('button', { name: 'Mark as former' }).click()
  await confirmDialog(page)
  await expect(empRow.locator('.badge', { hasText: 'former' })).toBeVisible()
  await expect(empRow).toContainText(`→ ${endDate}`)
})
