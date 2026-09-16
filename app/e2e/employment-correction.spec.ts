import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Correcting an employment record (migration 0037): the start date the import
 * got wrong is fixed in place — the period keeps its id, the old picture is
 * kept with a reason, and a date that would overlap another employment is
 * refused in words rather than as a constraint name.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Correction Subject'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let personId = ''
let currentPeriodId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  const ids = (people ?? []).map((p) => p.id)
  if (!ids.length) return
  const { data: periods } = await db.from('employment_periods').select('id').in('person_id', ids)
  const periodIds = (periods ?? []).map((p) => p.id)
  if (periodIds.length) await db.from('employment_corrections').delete().in('period_id', periodIds)
  await db.from('employment_periods').delete().in('person_id', ids)
  await db.from('people').delete().in('id', ids)
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('kind', 'company').is('archived_at', null).limit(1).single()
  if (!company) throw new Error('No company to employ into')
  const { data: person } = await db.from('people').insert({ full_name: PERSON }).select('id').single()
  personId = person!.id
  // A closed period, and a current one carrying the wrong start date.
  const { error: oldErr } = await db.from('employment_periods').insert({
    person_id: personId, company_id: company.id, job_title: 'Intern',
    employment_type_key: 'full_time', status: 'former',
    start_date: '2022-01-01', end_date: '2022-12-31',
  })
  if (oldErr) throw new Error(`Could not seed the closed period: ${oldErr.message}`)
  const { data: current, error } = await db
    .from('employment_periods')
    .insert({
      person_id: personId, company_id: company.id, job_title: 'Software Developer',
      employment_type_key: 'full_time', status: 'active', start_date: '2026-01-01',
    })
    .select('id')
    .single()
  if (error || !current) throw new Error(`Could not seed the period: ${error?.message}`)
  currentPeriodId = current.id
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('a wrong start date is corrected in place, an overlapping one is refused', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto(`/people/${personId}`)
  const row = page.locator('.emp-row', { hasText: 'Software Developer' })
  await row.getByRole('button', { name: 'Correct' }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog).toContainText('Correct')

  // A date inside the closed period is refused in words, not as a constraint.
  await dialog.locator('#cor-start').fill('2022-06-01')
  await dialog.getByRole('button', { name: 'Save correction' }).click()
  await expect(dialog.locator('.error-note')).toContainText(/overlaps another employment/)

  // The real correction: an earlier start and the title it should have had.
  await dialog.locator('#cor-start').fill('2024-11-01')
  await dialog.locator('#cor-title').fill('Senior Frontend Engineer')
  await dialog.locator('#cor-reason').fill('Contract says November 2024')
  await dialog.getByRole('button', { name: 'Save correction' }).click()
  await expect(page.getByText(/Record corrected/)).toBeVisible()

  // The period kept its id — everything hanging off it is still attached.
  const { data: period } = await db
    .from('employment_periods')
    .select('start_date, job_title, status')
    .eq('id', currentPeriodId)
    .single()
  expect(period?.start_date).toBe('2024-11-01')
  expect(period?.job_title).toBe('Senior Frontend Engineer')
  expect(period?.status).toBe('active')

  // The old picture is kept, with the reason.
  const { data: corrections } = await db
    .from('employment_corrections')
    .select('old_start_date, new_start_date, old_job_title, new_job_title, reason')
    .eq('period_id', currentPeriodId)
  expect(corrections).toHaveLength(1)
  expect(corrections![0]).toMatchObject({
    old_start_date: '2026-01-01',
    new_start_date: '2024-11-01',
    old_job_title: 'Software Developer',
    new_job_title: 'Senior Frontend Engineer',
    reason: 'Contract says November 2024',
  })
})
