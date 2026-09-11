import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * The full invite lifecycle, ported from the Hut4 leave system: admin invites
 * -> one-time temp password -> invitee signs in -> is locked to the forced
 * change screen (and out of all data) -> sets their own password -> sees only
 * their own record. Runs against the live Supabase project; cleans up after
 * itself with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const INVITEE_EMAIL = 'e2e-invitee@synami.com'
const INVITEE_NAME = 'E2E Invitee'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function removeInvitee(): Promise<void> {
  const db = serviceClient()
  await db.from('people').delete().eq('work_email', INVITEE_EMAIL)
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 200 })
    if (error || !data.users.length) break
    const match = data.users.find((u) => u.email === INVITEE_EMAIL)
    if (match) {
      await db.auth.admin.deleteUser(match.id)
      break
    }
    if (data.users.length < 200) break
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await removeInvitee() // idempotent re-runs
})

test.afterAll(async () => {
  await removeInvitee()
})

test('invite → temp password → forced change → self-service access', async ({ page }) => {
  // Admin signs in and invites.
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.getByRole('link', { name: 'People & access', exact: true }).click()
  await page.getByRole('button', { name: 'Invite person' }).click()
  await page.locator('#invite-name').fill(INVITEE_NAME)
  await page.locator('#invite-email').fill(INVITEE_EMAIL)
  await page.getByRole('button', { name: 'Create invitation' }).click()

  // The one-time credential is shown to the admin.
  const credential = page.locator('.credential code')
  await expect(credential).toBeVisible()
  const tempPassword = (await credential.textContent())?.trim() ?? ''
  expect(tempPassword).toMatch(/^[A-Za-z0-9]{20}$/)
  await page.getByRole('button', { name: 'Done' }).click()
  await expect(page.locator('tr', { hasText: INVITEE_NAME })).toBeVisible()
  await page.getByRole('button', { name: 'Sign out' }).click()

  // Invitee signs in with the temp password and is forced to change it.
  await page.locator('#email').fill(INVITEE_EMAIL)
  await page.locator('#password').fill(tempPassword)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page).toHaveURL(/\/change-password$/)
  await expect(page.getByRole('heading', { name: /own password/ })).toBeVisible()

  // Locked: navigating anywhere else bounces straight back.
  await page.goto('/directory')
  await expect(page).toHaveURL(/\/change-password$/)

  // The new password must differ and meet the policy; the checklist is live.
  const newPassword = `E2e-Chosen-${Date.now()}a1`
  await page.locator('#current').fill(tempPassword)
  await page.locator('#next').fill(newPassword)
  await page.locator('#confirm').fill(newPassword)
  await expect(page.locator('.password-rules li.met')).toHaveCount(5)
  await page.getByRole('button', { name: 'Set password' }).click()

  // In: the invitee lands on the overview, and in the directory sees ONLY
  // themself (no grants).
  await expect(page).toHaveURL(/\/overview$/)
  await page.goto('/directory')
  await expect(page.locator('tr', { hasText: INVITEE_NAME })).toBeVisible()
  await expect(page.locator('tbody tr')).toHaveCount(1)
  await expect(page.getByRole('button', { name: 'Invite person' })).toHaveCount(0)

  // The temp password is dead now.
  await page.getByRole('button', { name: 'Sign out' }).click()
  await page.locator('#email').fill(INVITEE_EMAIL)
  await page.locator('#password').fill(tempPassword)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page.getByRole('alert')).toContainText('not right')
})
