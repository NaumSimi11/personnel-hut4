import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Payroll preparation (plan 031): prepare a period on the company Payroll
 * tab, see the snapshot lines, be refused self-approval, approve a
 * colleague-prepared period, download the CSV, mark it exported.
 * Seeds one person at Praedium with an approved EUR record.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Payroll Subject'
const COLLEAGUE = 'E2E Payroll Colleague'
// A range no other spec uses, in the far future so nothing else overlaps.
const START = '2031-03-01'
const END = '2031-03-31'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''
let personId = ''
let colleagueId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (company) {
    await db.from('payroll_periods').delete().eq('company_id', company.id).eq('period_start', START)
  }
  const { data: people } = await db.from('people').select('id').in('full_name', [PERSON, COLLEAGUE])
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    const { data: periods } = await db.from('employment_periods').select('id').in('person_id', ids)
    const periodIds = (periods ?? []).map((p) => p.id)
    if (periodIds.length) await db.from('compensation_records').delete().in('employment_period_id', periodIds)
    await db.from('employment_periods').delete().in('person_id', ids)
    await db.from('people').delete().in('id', ids)
  }
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id
  const { data: person } = await db.from('people').insert({ full_name: PERSON }).select('id').single()
  personId = person!.id
  const { data: colleague } = await db.from('people').insert({ full_name: COLLEAGUE }).select('id').single()
  colleagueId = colleague!.id
  const { data: period, error } = await db
    .from('employment_periods')
    .insert({ person_id: personId, company_id: companyId, job_title: 'Payroll Clerk', status: 'active', start_date: '2024-01-15' })
    .select('id')
    .single()
  if (error || !period) throw new Error(`Could not seed the period: ${error?.message}`)
  const { error: recErr } = await db.from('compensation_records').insert({
    employment_period_id: period.id,
    amount: 2400,
    currency: 'EUR',
    pay_basis_key: 'monthly',
    effective_date: '2024-01-15',
    status: 'approved',
  })
  if (recErr) throw new Error(`Could not seed the record: ${recErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('prepare → lines → no self-approval → colleague-prepared approved → CSV → exported', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto(`/companies/${companyId}?tab=payroll`)
  await page.getByRole('tab', { name: 'Payroll' }).click()
  const periods = page.locator('.card', { hasText: 'Payroll periods' })
  await periods.getByRole('button', { name: 'Prepare a period' }).click()
  await periods.locator('#pp-start').fill(START)
  await periods.locator('#pp-end').fill(END)
  await periods.locator('#pp-currency').fill('eur')
  await periods.getByRole('button', { name: 'Prepare' }).click()
  const row = periods.locator('.period-row', { hasText: `${START} → ${END}` })
  await expect(row).toContainText('EUR')
  await expect(row).toContainText('In review')
  // The preparer never gets Approve on their own period.
  await expect(row.getByRole('button', { name: 'Approve' })).toHaveCount(0)

  // Lines.
  await row.getByRole('button', { name: 'Lines' }).click()
  const line = periods.locator('.line-row', { hasText: PERSON })
  await expect(line).toContainText('Payroll Clerk')
  await expect(line).toContainText('2,400 EUR')
  await expect(line).toContainText('monthly')
  await expect(line).toContainText('31 days')

  // A colleague prepared it (simulated): approve, download, export.
  await db.from('payroll_periods').update({ prepared_by: colleagueId }).eq('company_id', companyId).eq('period_start', START)
  await page.reload()
  await row.getByRole('button', { name: 'Approve' }).click()
  await expect(row).toContainText('Approved')

  const [download] = await Promise.all([page.waitForEvent('download'), row.getByRole('button', { name: 'Download CSV' }).click()])
  expect(download.suggestedFilename()).toBe(`payroll-prae-${START}-${END}-eur.csv`)
  const csv = await (await download.createReadStream()).toArray().then((chunks) => Buffer.concat(chunks).toString('utf8'))
  expect(csv.split('\n')[0]).toBe('Person,Job title,Amount,Currency,Pay basis,From,To,Days covered,Bonus,Gross,Tax,Deductions,Net')
  expect(csv).toContain(`${PERSON},Payroll Clerk,2400.00,EUR,monthly,${START},${END},31,0.00,2400.00,`)

  await row.getByRole('button', { name: 'Mark exported' }).click()
  await confirmDialog(page)
  await expect(row).toContainText('Exported')
  const { data: period } = await db
    .from('payroll_periods')
    .select('status, exported_at, approved_by')
    .eq('company_id', companyId)
    .eq('period_start', START)
    .single()
  expect(period?.status).toBe('exported')
  expect(period?.exported_at).not.toBeNull()
  expect(period?.approved_by).not.toBeNull()
})
