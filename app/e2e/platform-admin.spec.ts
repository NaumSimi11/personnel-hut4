import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Platform admins from the UI: on a person's access editor an admin makes
 * them a platform admin (confirm step), the directory shows the badge, and
 * the admin can be removed again; nobody can remove themselves. Seeds one
 * person and cleans up with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Admin Candidate'
const PERSON_EMAIL = 'e2e-admin-candidate@example.test'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let personId = ''
let adminPersonId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  for (const p of people ?? []) {
    await db.from('platform_admins').delete().eq('person_id', p.id)
    await db.from('people').delete().eq('id', p.id)
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  const db = serviceClient()
  const { data: admin } = await db.from('people').select('id').ilike('work_email', ADMIN_EMAIL).single()
  if (!admin) throw new Error("Could not find the test user's person row")
  adminPersonId = admin.id
  const { data: person } = await db.from('people').insert({ full_name: PERSON, work_email: PERSON_EMAIL }).select('id').single()
  if (!person) throw new Error('Could not seed the person')
  personId = person.id
})

test.afterAll(cleanup)

test('make a person a platform admin from the access editor, see the badge, remove again; self-removal is refused', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto(`/people/${personId}/access`)
  const panel = page.getByTestId('platform-admin-panel')
  await expect(panel.getByTestId('admin-status')).toContainText('Not a platform admin')
  await panel.getByTestId('admin-toggle').click()
  await expect(panel).toContainText('Give E2E full access to everything?')
  await panel.getByTestId('admin-confirm').click()
  await expect(panel.getByTestId('admin-status')).toContainText('Platform admin')
  await expect(panel).toContainText('since')
  const { data: row } = await db.from('platform_admins').select('granted_by').eq('person_id', personId).maybeSingle()
  expect(row?.granted_by).toBe(adminPersonId)

  // The directory says so.
  await page.goto('/directory')
  await page.getByPlaceholder(/Search/).fill(PERSON)
  await expect(page.locator('tr', { hasText: PERSON }).getByTestId('admin-badge')).toBeVisible()

  // Remove again.
  await page.goto(`/people/${personId}/access`)
  await panel.getByTestId('admin-toggle').click()
  await panel.getByTestId('admin-confirm').click()
  await expect(panel.getByTestId('admin-status')).toContainText('Not a platform admin')
  const { data: gone } = await db.from('platform_admins').select('person_id').eq('person_id', personId).maybeSingle()
  expect(gone).toBeNull()

  // Myself: the button is there but disabled, with the reason.
  await page.goto(`/people/${adminPersonId}/access`)
  await expect(panel.getByTestId('admin-toggle')).toBeDisabled()
  await expect(panel).toContainText('Ask another platform admin to remove you.')
})
