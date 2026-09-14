import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Hiring workspace part A: request a hire, approve it as the platform
 * admin (0030: admins may decide their own; everyone else never can —
 * covered by the smoke tests), approve a
 * service-created request, and send another back for changes. Cleans up
 * with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const TITLE_ALPHA = 'E2E Role Alpha'
const TITLE_BETA = 'E2E Role Beta'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function removeTestRequests(): Promise<void> {
  const db = serviceClient()
  await db.from('hiring_requests').delete().in('title', [TITLE_ALPHA, TITLE_BETA])
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await removeTestRequests()
})

test.afterAll(async () => {
  await removeTestRequests()
})

test('request a hire → changes requested → admin approves their own → service request approved', async ({
  page,
}) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()

  await page.getByRole('link', { name: 'Hiring' }).click()
  await expect(page.getByRole('heading', { name: 'One role. Every handoff connected.' })).toBeVisible()

  // Create the request from the UI — it lands as `submitted` with the
  // signed-in admin as requester.
  await page.getByRole('button', { name: 'Request a hire' }).click()
  await page.locator('#rh-company').selectOption({ label: 'Snowball' })
  await page.locator('#rh-title').fill(TITLE_ALPHA)
  await page.locator('#rh-headcount').fill('1')
  await page.getByRole('button', { name: 'Request hire' }).click()

  const alphaRow = page.locator('.request-row', { hasText: TITLE_ALPHA })
  await expect(alphaRow).toBeVisible()
  await expect(alphaRow.locator('.badge')).toHaveText('submitted')
  await expect(alphaRow).toContainText('Snowball')

  // Request changes on Alpha, with a reason surfaced on the row.
  page.once('dialog', (dialog) => dialog.accept('Need budget range'))
  await alphaRow.getByRole('button', { name: 'Request changes' }).click()
  await expect(alphaRow.locator('.badge')).toHaveText('changes requested')
  await expect(alphaRow).toContainText('Need budget range')

  // The requester is the platform admin, so they may decide their own
  // request (migration 0030), also from 'changes requested'; decided_by is still server-set.
  await alphaRow.getByRole('button', { name: 'Approve' }).click()
  await expect(alphaRow.locator('.badge')).toHaveText('approved')
  await expect(alphaRow).not.toContainText('a different approver')

  // A request with no requester (service-created) can be approved.
  const db = serviceClient()
  const { error: insertErr } = await db.from('hiring_requests').insert({
    title: TITLE_BETA,
    headcount: 1,
    status: 'submitted',
    requested_by: null,
    company_id: (
      await db.from('companies').select('id').eq('name', 'Snowball').single()
    ).data?.id,
  })
  expect(insertErr).toBeNull()

  await page.reload()
  const betaRow = page.locator('.request-row', { hasText: TITLE_BETA })
  await expect(betaRow).toBeVisible()
  await betaRow.getByRole('button', { name: 'Approve' }).click()
  await expect(betaRow.locator('.badge')).toHaveText('approved')

})
