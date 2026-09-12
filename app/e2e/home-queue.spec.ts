import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Home queue (plan 034): the later modules surface on the overview — a
 * compensation proposal by a colleague, a submitted document request, an
 * open IT request and a payroll period prepared by a colleague — each with
 * a link to where it is decided. Seeds one person and one colleague at
 * Praedium.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Queue Subject'
const COLLEAGUE = 'E2E Queue Colleague'
const IT_TITLE = 'E2E Queue badge access'
const START = '2032-01-01'
const END = '2032-01-31'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''
let personId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (company) {
    await db.from('payroll_periods').delete().eq('company_id', company.id).eq('period_start', START)
    await db.from('it_requests').delete().eq('company_id', company.id).eq('title', IT_TITLE)
  }
  const { data: people } = await db.from('people').select('id').in('full_name', [PERSON, COLLEAGUE])
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    await db.from('document_requests').delete().in('person_id', ids)
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
  const { data: period } = await db
    .from('employment_periods')
    .insert({ person_id: personId, company_id: companyId, job_title: 'Analyst', status: 'active', start_date: '2024-01-01' })
    .select('id')
    .single()
  // A colleague's proposal awaiting a decision.
  await db.from('compensation_records').insert({
    employment_period_id: period!.id,
    amount: 50000,
    currency: 'EUR',
    pay_basis_key: 'annual',
    effective_date: '2033-01-01',
    status: 'proposed',
    proposed_by: colleague!.id,
  })
  // A submitted document request (the service role bypasses the pinning trigger's auth check).
  const { data: request } = await db
    .from('document_requests')
    .insert({ company_id: companyId, person_id: personId, category_key: 'identification' })
    .select('id')
    .single()
  await db.from('document_requests').update({ status: 'submitted' }).eq('id', request!.id)
  // An open IT request.
  await db.from('it_requests').insert({ company_id: companyId, person_id: personId, kind: 'manual', title: IT_TITLE })
  // A payroll period prepared by the colleague.
  const { data: payroll } = await db
    .from('payroll_periods')
    .insert({ company_id: companyId, period_start: START, period_end: END, currency: 'EUR' })
    .select('id')
    .single()
  await db.from('payroll_periods').update({ status: 'in_review', prepared_by: colleague!.id }).eq('id', payroll!.id)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('the overview queue lists what waits on me across the later modules', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  const queue = page.locator('.queue-card')
  await expect(queue.locator('.queue-row', { hasText: `Compensation: ${PERSON}` })).toContainText('awaiting your decision')
  await expect(queue.locator('.queue-row', { hasText: PERSON }).filter({ hasText: 'Document to review: Identification' })).toBeVisible()
  await expect(queue.locator('.queue-row', { hasText: `IT request: ${IT_TITLE}` })).toContainText(`for ${PERSON}`)
  const payrollRow = queue.locator('.queue-row', { hasText: `Payroll: ${START} → ${END} EUR` })
  await expect(payrollRow).toContainText('awaiting your approval')

  await payrollRow.getByRole('link', { name: 'Review' }).click()
  await expect(page).toHaveURL(new RegExp(`/companies/${companyId}\\?tab=payroll`))
  await expect(page.locator('.period-row', { hasText: `${START} → ${END}` })).toContainText('In review')
})
