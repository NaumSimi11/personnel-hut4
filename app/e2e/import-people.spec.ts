import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * People import (plan 032): paste a CSV on the directory, preview the
 * verdicts (one row refused for an existing email), fix the file, import,
 * see the people in the directory with their manager link. Seeds one
 * existing person at Praedium whose email the file reuses.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const RUN_ID = Date.now().toString(36)
const EXISTING = 'E2E Import Existing'
const EXISTING_EMAIL = `e2e-import-existing-${RUN_ID}@example.test`
const LEAD = 'E2E Import Lead'
const LEAD_EMAIL = `e2e-import-lead-${RUN_ID}@example.test`
const JUNIOR = 'E2E Import Junior'
const JUNIOR_EMAIL = `e2e-import-junior-${RUN_ID}@example.test`

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').in('full_name', [EXISTING, LEAD, JUNIOR])
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    await db.from('employment_periods').update({ manager_id: null }).in('person_id', ids)
    await db.from('employment_periods').delete().in('person_id', ids)
    await db.from('people').delete().in('id', ids)
  }
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id
  const { data: person } = await db.from('people').insert({ full_name: EXISTING, work_email: EXISTING_EMAIL }).select('id').single()
  await db.from('employment_periods').insert({ person_id: person!.id, company_id: companyId, job_title: 'Existing', status: 'active', start_date: '2023-01-01' })
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('paste CSV → preview with a refused row → fix → import → directory', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto('/directory')
  await page.getByRole('button', { name: 'Import people' }).click()
  const dialog = page.getByRole('dialog')
  await dialog.locator('#import-company').selectOption({ label: 'Praedium' })
  const badCsv = [
    'Full Name,Email,Job Title,Start,Manager email',
    `${LEAD},${LEAD_EMAIL},Team Lead,2024-03-01,`,
    `${JUNIOR},${JUNIOR_EMAIL},Junior,15/09/2026,${LEAD_EMAIL}`,
    `${EXISTING},${EXISTING_EMAIL},Existing,2023-01-01,`,
  ].join('\n')
  await dialog.locator('#import-csv').fill(badCsv)
  await dialog.getByRole('button', { name: 'Preview' }).click()
  await expect(dialog.locator('.verdict-summary')).toContainText('2 ready')
  await expect(dialog.locator('.verdict-summary')).toContainText('1 refused')
  await expect(dialog.locator('.verdict-row', { hasText: EXISTING })).toContainText('already exists')
  await expect(dialog.getByRole('button', { name: 'Import 2 people' })).toBeDisabled()

  // Fix the file: drop the refused row.
  await dialog.locator('#import-csv').fill(badCsv.split('\n').slice(0, 3).join('\n'))
  await dialog.getByRole('button', { name: 'Preview' }).click()
  await expect(dialog.locator('.verdict-summary')).toContainText('2 ready')
  await dialog.getByRole('button', { name: 'Import 2 people' }).click()
  await expect(dialog.getByText('Imported 2 people')).toBeVisible()
  await dialog.getByRole('button', { name: 'Close' }).click()

  await expect(page.locator('tr', { hasText: LEAD })).toBeVisible()
  await expect(page.locator('tr', { hasText: JUNIOR })).toBeVisible()
  const { data: juniorPerson } = await db.from('people').select('id').eq('work_email', JUNIOR_EMAIL).single()
  const { data: period, error: periodErr } = await db
    .from('employment_periods')
    .select('job_title, start_date, status, manager:people!employment_periods_manager_id_fkey(full_name)')
    .eq('person_id', juniorPerson!.id)
    .single()
  expect(periodErr).toBeNull()
  const manager = period?.manager as unknown as { full_name: string } | null
  expect(period?.job_title).toBe('Junior')
  expect(period?.start_date).toBe('2026-09-15')
  expect(manager?.full_name).toBe(LEAD)
})
