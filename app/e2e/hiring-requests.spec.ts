import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Hiring workspace part A: request a hire, see the self-approval rule
 * enforced (requesters can never decide their own request), approve a
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

test('request a hire → self-approval refused → service request approved → changes requested', async ({
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

  // The requester (the signed-in admin) cannot decide their own request —
  // the database trigger refuses it, and the page must surface that as a
  // friendly message rather than the raw Postgres error.
  await alphaRow.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByRole('alert')).toContainText(
    'You requested this hire — a different approver must decide it.',
  )
  await expect(alphaRow.locator('.badge')).toHaveText('submitted')

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

  // Request changes on Alpha, with a reason surfaced on the row.
  page.once('dialog', (dialog) => dialog.accept('Need budget range'))
  await alphaRow.getByRole('button', { name: 'Request changes' }).click()
  await expect(alphaRow.locator('.badge')).toHaveText('changes requested')
  await expect(alphaRow).toContainText('Need budget range')
})
