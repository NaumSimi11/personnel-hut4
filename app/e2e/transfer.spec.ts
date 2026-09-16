import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Company structure (plan 035a): the holding employs people, a transfer
 * moves someone between companies as one act, and a company with people
 * still employed cannot be archived until they are transferred. Seeds a
 * closing company and one person employed there.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Transfer Subject'
const CLOSING = 'E2E Closing Co'
const CLOSING_CODE = 'E2EC'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let holdingId = ''
let closingId = ''
let personId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    const { data: periods } = await db.from('employment_periods').select('id').in('person_id', ids)
    const periodIds = (periods ?? []).map((p) => p.id)
    if (periodIds.length) {
      await db.from('employment_changes').delete().in('employment_period_id', periodIds)
      await db.from('employment_periods').update({ transferred_to_period_id: null }).in('id', periodIds)
    }
    await db.from('employment_periods').delete().in('person_id', ids)
    await db.from('people').delete().in('id', ids)
  }
  const { data: closing } = await db.from('companies').select('id').eq('short_code', CLOSING_CODE)
  for (const c of closing ?? []) {
    await db.from('employment_periods').delete().eq('company_id', c.id)
    await db.from('companies').delete().eq('id', c.id)
  }
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: holding } = await db.from('companies').select('id').eq('kind', 'holding').single()
  if (!holding) throw new Error('Holding not found')
  holdingId = holding.id
  const { data: closing, error: cErr } = await db
    .from('companies')
    .insert({ name: CLOSING, short_code: CLOSING_CODE, kind: 'company', parent_company_id: holdingId })
    .select('id')
    .single()
  if (cErr || !closing) throw new Error(`Could not seed the closing company: ${cErr?.message}`)
  closingId = closing.id
  const { data: person } = await db.from('people').insert({ full_name: PERSON }).select('id').single()
  personId = person!.id
  const { error } = await db
    .from('employment_periods')
    .insert({ person_id: personId, company_id: closingId, job_title: 'Bookkeeper', employment_type_key: 'full_time', status: 'active', start_date: '2024-02-01' })
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

test('holding employs → archive refused while employed → transfer to the holding → archived', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // The holding is a real employer: it has a headcount and opens like any company.
  await page.goto('/companies')
  const banner = page.locator('.holding-banner')
  await expect(banner).toContainText(/\d+ (person|people)/)
  await banner.getByRole('link', { name: /Open/ }).click()
  await expect(page).toHaveURL(new RegExp(`/companies/${holdingId}`))

  // Archiving a company with someone employed is refused and shows who.
  await page.goto(`/companies/${closingId}`)
  await page.getByRole('button', { name: 'Archive this company' }).click()
  await confirmDialog(page)
  await expect(page.locator('.archive-error')).toContainText('1 person is still employed here')
  const blocked = page.locator('.still-employed .row', { hasText: PERSON })
  await expect(blocked).toBeVisible()

  // Transfer them to the holding from that list.
  await blocked.getByRole('button', { name: 'Transfer' }).click()
  const dialog = page.getByRole('dialog')
  await dialog.locator('#tr-company').selectOption({ label: 'Hut4' })
  await dialog.locator('#tr-title').fill('Group Bookkeeper')
  await dialog.locator('#tr-reason').fill('Company closing')
  await dialog.getByRole('button', { name: 'Transfer' }).click()
  await expect(page.getByText(/Transferred to Hut4/)).toBeVisible()

  const { data: periods } = await db
    .from('employment_periods')
    .select('job_title, status, end_date, company_id, transferred_to_period_id')
    .eq('person_id', personId)
    .order('start_date')
  expect(periods?.map((p) => [p.job_title, p.status, p.company_id])).toEqual([
    ['Bookkeeper', 'former', closingId],
    ['Group Bookkeeper', 'active', holdingId],
  ])
  expect(periods?.[0]?.transferred_to_period_id).not.toBeNull()
  expect(periods?.[0]?.end_date).not.toBeNull()

  // The profile tells the story: former here, active at the holding.
  await page.goto(`/people/${personId}`)
  await expect(page.locator('.emp-row', { hasText: 'Group Bookkeeper · Hut4' }).locator('.badge', { hasText: 'active' })).toBeVisible()
  await expect(page.locator('.emp-row', { hasText: `Bookkeeper · ${CLOSING}` }).locator('.badge', { hasText: 'former' })).toBeVisible()

  // Now the company can close; nothing was deleted.
  await page.goto(`/companies/${closingId}`)
  await page.getByRole('button', { name: 'Archive this company' }).click()
  await confirmDialog(page)
  await expect(page).toHaveURL(/\/companies$/)
  const { data: company } = await db.from('companies').select('archived_at').eq('id', closingId).single()
  expect(company?.archived_at).not.toBeNull()
  const { count } = await db.from('employment_periods').select('*', { count: 'exact', head: true }).eq('company_id', closingId)
  expect(count).toBe(1)
})
