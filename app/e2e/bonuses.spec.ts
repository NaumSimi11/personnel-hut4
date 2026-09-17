import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Bonuses and the net estimate (plan 051): Settings → Payroll estimate sets
 * the rate and the flat deduction; a bonus recorded on the Payroll tab
 * waits, lands in the next prepared period once, the line shows the
 * estimate, reopening the period sends the bonus back to pending and holds
 * Approve until the period is prepared again.
 * Seeds one person at Praedium with an approved EUR record; restores the
 * company's payroll settings afterwards.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Bonus Subject'
const COLLEAGUE = 'E2E Bonus Colleague'
const REASON = 'E2E quarter target met'
// A range no other spec uses.
const START = '2031-05-01'
const END = '2031-05-31'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''
let personId = ''
let colleagueId = ''
let previousSettings: Record<string, unknown> | null = null

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id, settings').eq('short_code', 'PRAE').single()
  if (company) {
    await db.from('payroll_items').delete().eq('company_id', company.id).eq('reason', REASON)
    await db.from('payroll_periods').delete().eq('company_id', company.id).eq('period_start', START)
    if (previousSettings) {
      const settings = { ...((company.settings as Record<string, unknown>) ?? {}) }
      if (previousSettings.payroll === undefined) delete settings.payroll
      else settings.payroll = previousSettings.payroll
      await db.from('companies').update({ settings }).eq('id', company.id)
      previousSettings = null
    }
  }
  const { data: people } = await db.from('people').select('id').in('full_name', [PERSON, COLLEAGUE])
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    await db.from('payroll_items').delete().in('person_id', ids)
    const { data: periods } = await db.from('employment_periods').select('id').in('person_id', ids)
    const periodIds = (periods ?? []).map((p) => p.id)
    if (periodIds.length) await db.from('compensation_records').delete().in('employment_period_id', periodIds)
    await db.from('employment_periods').delete().in('person_id', ids)
    await db.from('people').delete().in('id', ids)
  }
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id, settings').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id
  const settings = (company.settings as Record<string, unknown>) ?? {}
  previousSettings = { payroll: settings.payroll }
  const { data: person } = await db.from('people').insert({ full_name: PERSON }).select('id').single()
  personId = person!.id
  const { data: colleague } = await db.from('people').insert({ full_name: COLLEAGUE }).select('id').single()
  colleagueId = colleague!.id
  const { data: period, error } = await db
    .from('employment_periods')
    .insert({ person_id: personId, company_id: companyId, job_title: 'Bonus Clerk', status: 'active', start_date: '2024-01-15' })
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

test('settings → bonus → prepare → the line shows net → reopen → the bonus is pending again → prepare again → approve', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // Settings → Payroll estimate: 10 % and a flat 50.
  await page.goto(`/companies/${companyId}?tab=settings`)
  await page.getByRole('tab', { name: 'Settings' }).click()
  const settings = page.getByTestId('payroll-settings-panel')
  await expect(settings).toContainText('statutory contributions are the accountant')
  await settings.locator('#ps-rate').fill('10')
  await settings.locator('#ps-flat').fill('50')
  await expect(settings.getByTestId('payroll-preview')).toContainText('tax 100, net 850')
  await settings.getByTestId('payroll-settings-save').click()
  await expect(settings).toContainText('Payroll settings saved')
  await expect(settings).toContainText("Praedium's own numbers")

  // Payroll → a bonus for the person.
  await page.getByRole('tab', { name: 'Payroll' }).click()
  const bonuses = page.getByTestId('bonuses-panel')
  await bonuses.getByTestId('bonus-add').click()
  await bonuses.locator('#bonus-person').selectOption({ label: PERSON })
  await bonuses.locator('#bonus-amount').fill('250')
  await bonuses.locator('#bonus-currency').fill('eur')
  await bonuses.locator('#bonus-reason').fill(REASON)
  await bonuses.locator('#bonus-date').fill('2031-05-10')
  await bonuses.getByRole('button', { name: 'Record bonus' }).click()
  await expect(bonuses).toContainText(`Bonus for ${PERSON} recorded`)
  const pending = bonuses.getByTestId('bonus-pending').filter({ hasText: PERSON })
  await expect(pending).toContainText('250 EUR')
  await expect(pending).toContainText(REASON)

  // Prepare the period: the bonus goes in, the line shows the estimate.
  const periods = page.locator('.card', { hasText: 'Payroll periods' })
  await periods.getByRole('button', { name: 'Prepare a period' }).click()
  await periods.locator('#pp-start').fill(START)
  await periods.locator('#pp-end').fill(END)
  await periods.locator('#pp-currency').fill('eur')
  await periods.getByRole('button', { name: 'Prepare' }).click()
  await expect(periods).toContainText('1 bonus included')
  const row = periods.locator('.period-row', { hasText: `${START} → ${END}` })
  await expect(row).toContainText('In review')
  await row.getByRole('button', { name: 'Lines' }).click()
  const line = periods.getByTestId('payroll-line').filter({ hasText: PERSON })
  await expect(line).toContainText('2,400 EUR monthly')
  await expect(line.getByTestId('line-estimate')).toContainText('bonus 250 EUR · gross 2,650 EUR · tax 265 EUR · deductions 50 EUR · net 2,335 EUR')
  await expect(periods.getByTestId('period-totals')).toContainText('statutory contributions are the accountant')
  await expect(periods.getByTestId('period-totals')).toContainText('(10%)')
  await expect(bonuses.getByTestId('bonus-included').filter({ hasText: PERSON })).toContainText(`in ${START} → ${END}`)
  await expect(bonuses.getByTestId('bonus-pending').filter({ hasText: PERSON })).toHaveCount(0)

  // The CSV carries the estimate after the accountant's columns.
  const [download] = await Promise.all([page.waitForEvent('download'), row.getByRole('button', { name: 'Download CSV' }).click()])
  const csv = await (await download.createReadStream()).toArray().then((chunks) => Buffer.concat(chunks).toString('utf8'))
  expect(csv.split('\n')[0]).toBe('Person,Job title,Amount,Currency,Pay basis,From,To,Days covered,Bonus,Gross,Tax,Deductions,Net')
  expect(csv).toContain(`${PERSON},Bonus Clerk,2400.00,EUR,monthly,${START},${END},31,250.00,2650.00,265.00,50.00,2335.00`)

  // A colleague prepared it (simulated): approve, reopen → the bonus is pending again, Approve waits.
  await db.from('payroll_periods').update({ prepared_by: colleagueId }).eq('company_id', companyId).eq('period_start', START)
  await page.reload()
  await row.getByRole('button', { name: 'Approve' }).click()
  await expect(row).toContainText('Approved')
  await row.getByRole('button', { name: 'Reopen' }).click()
  await expect(periods).toContainText('1 bonus is pending again')
  await expect(row.getByTestId('period-reopened')).toContainText('prepare again before approving')
  await expect(row.getByRole('button', { name: 'Approve' })).toHaveCount(0)
  await expect(bonuses.getByTestId('bonus-pending').filter({ hasText: PERSON })).toHaveCount(1)
  const { data: item } = await db.from('payroll_items').select('period_id').eq('reason', REASON).single()
  expect(item?.period_id).toBeNull()

  // Prepare again: the bonus is back in; a colleague-prepared period approves.
  await row.getByRole('button', { name: 'Prepare again' }).click()
  await confirmDialog(page)
  await expect(periods).toContainText('1 bonus included')
  await expect(row.getByTestId('period-reopened')).toHaveCount(0)
  await db.from('payroll_periods').update({ prepared_by: colleagueId }).eq('company_id', companyId).eq('period_start', START)
  await page.reload()
  await row.getByRole('button', { name: 'Approve' }).click()
  await expect(row).toContainText('Approved')
  const { data: after } = await db.from('payroll_items').select('period_id').eq('reason', REASON).single()
  expect(after?.period_id).not.toBeNull()
})
