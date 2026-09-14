import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Compensation (plan 023): the profile shows the current approved amount,
 * a proposal goes in through the form, the proposer never sees Approve on
 * their own proposal, another approver's decision supersedes the previous
 * record (history intact), the company Payroll tab totals annualised pay,
 * and My workspace shows the signed-in person's own compensation.
 * Seeds one subject at Praedium plus a short employment for the admin.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Pay Subject'
const COLLEAGUE = 'E2E Pay Colleague'
const ADMIN_TITLE = 'E2E Pay Admin Role'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''
let personId = ''
let colleagueId = ''
let periodId = ''
let adminPeriodId = ''

async function findAdminPersonId(): Promise<string> {
  const db = serviceClient()
  const { data: users, error } = await db.auth.admin.listUsers({ perPage: 1000 })
  const user = users?.users.find((u) => u.email?.toLowerCase() === ADMIN_EMAIL.toLowerCase())
  if (error || !user) throw new Error(`Could not find the auth user for TEST_USER_EMAIL: ${error?.message}`)
  const { data } = await db.from('people').select('id').eq('user_id', user.id).single()
  if (!data) throw new Error("Could not find the admin's person row")
  return data.id
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').in('full_name', [PERSON, COLLEAGUE])
  const ids = (people ?? []).map((p) => p.id)
  const { data: adminPeriods } = await db.from('employment_periods').select('id').eq('job_title', ADMIN_TITLE)
  const { data: subjectPeriods } = ids.length
    ? await db.from('employment_periods').select('id').in('person_id', ids)
    : { data: [] }
  const periodIds = [...(adminPeriods ?? []), ...(subjectPeriods ?? [])].map((p) => p.id)
  if (periodIds.length) {
    await db.from('compensation_records').delete().in('employment_period_id', periodIds)
    await db.from('employment_periods').delete().in('id', periodIds)
  }
  if (ids.length) await db.from('people').delete().in('id', ids)
  // The admin's own record rides on their real employment when they have one (see seed): remove it by its signature.
  const adminPersonId = await findAdminPersonId().catch(() => null)
  if (adminPersonId) {
    const { data: own } = await db.from('employment_periods').select('id').eq('person_id', adminPersonId)
    const ownIds = (own ?? []).map((p) => p.id)
    if (ownIds.length) {
      await db.from('compensation_records').delete().in('employment_period_id', ownIds).eq('amount', 5000).eq('pay_basis_key', 'monthly').eq('effective_date', '2024-01-01')
    }
  }
}

async function seed(adminPersonId: string): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id

  const { data: subject } = await db.from('people').insert({ full_name: PERSON }).select('id').single()
  personId = subject!.id
  const { data: colleague } = await db.from('people').insert({ full_name: COLLEAGUE }).select('id').single()
  colleagueId = colleague!.id

  const { data: period, error: periodErr } = await db
    .from('employment_periods')
    .insert({ person_id: personId, company_id: companyId, job_title: 'Warehouse Lead', status: 'active', start_date: '2024-03-01' })
    .select('id')
    .single()
  if (periodErr || !period) throw new Error(`Could not seed the period: ${periodErr?.message}`)
  periodId = period.id
  const { error: recErr } = await db.from('compensation_records').insert({
    employment_period_id: periodId,
    amount: 60000,
    currency: 'EUR',
    pay_basis_key: 'annual',
    effective_date: '2024-03-01',
    status: 'approved',
    approved_by: colleagueId,
  })
  if (recErr) throw new Error(`Could not seed the record: ${recErr.message}`)

  // The admin may already be employed for real (the Field Notebook import gave them a period);
  // a second overlapping period is refused by the database, so ride on the existing one.
  const { data: existing } = await db
    .from('employment_periods')
    .select('id')
    .eq('person_id', adminPersonId)
    .in('status', ['active', 'pre_start'])
    .limit(1)
    .maybeSingle()
  if (existing) {
    adminPeriodId = existing.id
  } else {
    const { data: adminPeriod, error: adminErr } = await db
      .from('employment_periods')
      .insert({ person_id: adminPersonId, company_id: companyId, job_title: ADMIN_TITLE, status: 'active', start_date: '2024-01-01' })
      .select('id')
      .single()
    if (adminErr || !adminPeriod) throw new Error(`Could not seed the admin period: ${adminErr?.message}`)
    adminPeriodId = adminPeriod.id
  }
  await db.from('compensation_records').insert({
    employment_period_id: adminPeriodId,
    amount: 5000,
    currency: 'EUR',
    pay_basis_key: 'monthly',
    effective_date: '2024-01-01',
    status: 'approved',
    approved_by: colleagueId,
  })
}

/** What the Payroll tab must show, computed independently of the app. */
async function expectedAnnualised(currency: string): Promise<number> {
  const db = serviceClient()
  const today = new Date().toISOString().slice(0, 10)
  const { data } = await db
    .from('compensation_records')
    .select('amount, pay_basis_key, effective_date, end_date, period:employment_periods!inner(company_id, status)')
    .eq('status', 'approved')
    .eq('currency', currency)
    .eq('period.company_id', companyId)
    .neq('period.status', 'former')
    .lte('effective_date', today)
  const factors: Record<string, number> = { annual: 1, monthly: 12, daily: 260, hourly: 2080 }
  return (data ?? [])
    .filter((r) => r.end_date === null || r.end_date >= today)
    .reduce((sum, r) => sum + Number(r.amount) * (factors[r.pay_basis_key] ?? 1), 0)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed(await findAdminPersonId())
})

test.afterAll(async () => {
  await cleanup()
})

test('current → propose → no self-approval → colleague approves → history → payroll → my workspace', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // Current approved amount on the profile.
  await page.goto(`/people/${personId}`)
  const card = page.locator('.card', { hasText: 'Compensation' })
  await expect(card.locator('.comp-current')).toContainText('60,000 EUR annual')
  await expect(card.locator('.comp-current')).toContainText('since 2024-03-01')

  // Propose a change effective at the start of this year.
  await card.getByRole('button', { name: 'Propose change' }).click()
  await card.locator('#comp-amount').fill('66000')
  await card.locator('#comp-currency').fill('eur')
  await card.locator('#comp-basis').selectOption('annual')
  await card.locator('#comp-effective').fill('2026-01-01')
  await card.locator('#comp-note').fill('Annual review')
  await card.getByRole('button', { name: 'Submit proposal' }).click()
  await expect(card.getByText('Proposal submitted')).toBeVisible()
  const pending = card.locator('.comp-pending')
  await expect(pending).toContainText('66,000 EUR annual')
  await expect(pending).toContainText('from 2026-01-01')
  // The proposer never gets to decide their own proposal.
  await expect(pending.getByRole('button', { name: 'Approve' })).toHaveCount(0)
  await expect(card.getByRole('button', { name: 'Propose change' })).toHaveCount(0)

  // Someone else proposed it (simulated): the approver now sees the decision buttons.
  const { data: proposal } = await db
    .from('compensation_records')
    .select('id')
    .eq('employment_period_id', periodId)
    .eq('status', 'proposed')
    .single()
  await db.from('compensation_records').update({ proposed_by: colleagueId }).eq('id', proposal!.id)
  await page.reload()
  await pending.getByRole('button', { name: 'Approve' }).click()
  await expect(card.getByText('Proposal approved')).toBeVisible()
  await expect(card.locator('.comp-current')).toContainText('66,000 EUR annual')
  await expect(card.locator('.comp-current')).toContainText('since 2026-01-01')
  const history = card.locator('.comp-history-row')
  await expect(history.filter({ hasText: '60,000 EUR' })).toContainText('Superseded')
  await expect(history.filter({ hasText: '60,000 EUR' })).toContainText('2024-03-01 → 2025-12-31')

  const { data: records } = await db
    .from('compensation_records')
    .select('amount, status, end_date')
    .eq('employment_period_id', periodId)
    .order('effective_date')
  expect(records).toEqual([
    { amount: 60000, status: 'approved', end_date: '2025-12-31' },
    { amount: 66000, status: 'approved', end_date: null },
  ])

  // Payroll tab: annualised EUR total matches an independent computation.
  const eur = await expectedAnnualised('EUR')
  await page.goto(`/companies/${companyId}?tab=payroll`)
  await page.getByRole('tab', { name: 'Payroll' }).click()
  const eurRow = page.locator('.payroll-total', { hasText: 'EUR' })
  await expect(eurRow).toContainText(new Intl.NumberFormat('en-US').format(eur))
  await expect(page.locator('.payroll-coverage')).toContainText('with an approved record')

  // My workspace: the admin's own compensation.
  await page.goto('/me')
  const mine = page.locator('.card', { hasText: 'My compensation' })
  await expect(mine).toContainText('5,000 EUR monthly')
})
