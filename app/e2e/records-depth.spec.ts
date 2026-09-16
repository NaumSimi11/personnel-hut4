import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Employee records depth: invite <-> record unification (attach to an
 * existing record-only person instead of duplicating, refuse when they
 * already have an account) plus the private-details card. Runs against the
 * live Supabase project; cleans up after itself with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON_NAME = 'E2E Attach Target'
const PERSON_EMAIL = 'e2e-attach@synami.com'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function removeTestPerson(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db
    .from('people')
    .select('id')
    .or(`full_name.eq.${PERSON_NAME},work_email.eq.${PERSON_EMAIL}`)
  for (const person of people ?? []) {
    // Add employee starts the onboarding checklist (plan 046).
    const { data: plans } = await db.from('plans').select('id').eq('person_id', person.id)
    const planIds = (plans ?? []).map((p) => p.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', person.id)
    await db.from('employment_periods').delete().eq('person_id', person.id)
    await db.from('person_private_details').delete().eq('person_id', person.id)
    await db.from('people').delete().eq('id', person.id)
  }
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 200 })
    if (error || !data.users.length) break
    const match = data.users.find((u) => u.email === PERSON_EMAIL)
    if (match) {
      await db.auth.admin.deleteUser(match.id)
      break
    }
    if (data.users.length < 200) break
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await removeTestPerson() // idempotent re-runs
})

test.afterAll(async () => {
  await removeTestPerson()
})

test('add person → invite attaches (no duplicate) → private details persist → re-invite refused', async ({
  page,
}) => {
  // Admin signs in.
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.getByRole('link', { name: 'People & access', exact: true }).click()

  // 1. Add a record-only person (no account yet).
  await page.getByRole('button', { name: 'Add employee' }).click()
  const add = page.getByTestId('add-employee-dialog')
  await add.locator('#ae-name').fill(PERSON_NAME)
  await add.locator('#ae-work-email').fill(PERSON_EMAIL)
  await add.locator('#ae-company').selectOption({ label: 'Praedium' })
  await add.locator('#ae-title').fill('Attach Probe')
  await add.getByRole('button', { name: 'Create employee' }).click()
  await add.getByRole('button', { name: 'Done' }).click()
  const row = page.locator('tr', { hasText: PERSON_NAME })
  await expect(row).toBeVisible()

  // 2. Profile shows record-only, no account.
  await row.getByRole('link', { name: PERSON_NAME }).click()
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  await expect(page.getByText('no account — record only')).toBeVisible()

  // 3. Inviting the same email attaches to the existing record instead of
  // creating a duplicate — the submitted name is ignored.
  await page.goto('/directory')
  await page.getByRole('button', { name: 'Invite person' }).click()
  await page.locator('#invite-name').fill('Ignored Name')
  await page.locator('#invite-email').fill(PERSON_EMAIL)
  await page.getByRole('button', { name: 'Create invitation' }).click()
  await expect(page.locator('.credential code')).toBeVisible()
  await page.getByRole('button', { name: 'Done' }).click()

  await expect(page.locator('tbody tr', { hasText: PERSON_NAME })).toHaveCount(1)
  await expect(page.locator('tbody tr', { hasText: 'Ignored Name' })).toHaveCount(0)

  // 4. Profile now shows a sign-in account, still under the original name.
  await page.locator('tr', { hasText: PERSON_NAME }).getByRole('link', { name: PERSON_NAME }).click()
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  await expect(page.getByText('has sign-in account')).toBeVisible()

  // 5. Private details: fill in, save, reload, confirm persistence.
  await page.getByRole('button', { name: 'Add details' }).click()
  await page.locator('#pd-birth').fill('1990-05-04')
  await page.locator('#pd-address').fill('Test Street 1')
  await page.locator('#pd-emergency-name').fill('Jane Doe')
  await page.locator('#pd-emergency-phone').fill('555-0100')
  await page.getByRole('button', { name: 'Save' }).click()
  await expect(page.getByText('Private details saved.')).toBeVisible()

  await page.reload()
  await expect(page.getByText('Test Street 1')).toBeVisible()
  await expect(page.getByText('Jane Doe · 555-0100')).toBeVisible()
  await expect(page.getByText('1990-05-04')).toBeVisible()

  // 6. Inviting the same email again is refused — the person already has an account.
  await page.goto('/directory')
  await page.getByRole('button', { name: 'Invite person' }).click()
  await page.locator('#invite-name').fill('Ignored Name Again')
  await page.locator('#invite-email').fill(PERSON_EMAIL)
  await page.getByRole('button', { name: 'Create invitation' }).click()
  await expect(page.getByRole('alert')).toContainText('Reset access')
})
