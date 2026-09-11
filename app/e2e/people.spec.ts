import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

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

  // Create the record with its first employment at Praedium.
  await page.getByRole('button', { name: 'Add person' }).click()
  await page.locator('#ap-name').fill(PERSON_NAME)
  await page.locator('#ap-company').selectOption({ label: 'Praedium' })
  await page.locator('#ap-title').fill('Warehouse Lead')
  await page.getByRole('button', { name: 'Create employee' }).click()

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

  // End the employment (native confirm) — history stays, status flips.
  page.once('dialog', (dialog) => dialog.accept())
  await empRow.getByRole('button', { name: 'End employment' }).click()
  await expect(empRow.locator('.badge')).toHaveText('former')
  await expect(empRow).toContainText('→ ')
})
