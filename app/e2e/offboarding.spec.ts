import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Offboarding (plan 016): a departure is scheduled from the person's
 * employment row (dates + restricted reason → schedule_departure, migration
 * 0010), shows up in the Offboarding queue with its blockers, and the person
 * becomes Former only through the explicit finish (complete_departure), which
 * is allowed while tasks are still open. Seeds an active employee at
 * Praedium with the service client; cleans up before and after.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON_NAME = 'E2E Departing Employee'
const COMPANY_SHORT_CODE = 'PRAE'
const REASON = 'Relocating abroad (e2e)'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

function daysFromNow(days: number): string {
  const d = new Date()
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

const END_DATE = daysFromNow(21)
const LAST_WORKING_DATE = daysFromNow(14)

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: person } = await db.from('people').select('id').eq('full_name', PERSON_NAME).maybeSingle()
  if (person) {
    const { data: plans } = await db.from('plans').select('id').eq('person_id', person.id)
    const planIds = (plans ?? []).map((p) => p.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', person.id)
    const { data: periods } = await db.from('employment_periods').select('id').eq('person_id', person.id)
    const periodIds = (periods ?? []).map((p) => p.id)
    if (periodIds.length) {
      await db.from('employment_departure_details').delete().in('employment_period_id', periodIds)
    }
    await db.from('employment_periods').delete().eq('person_id', person.id)
  }
  await db.from('people').delete().eq('full_name', PERSON_NAME)
}

let seededPersonId = ''

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company, error: companyErr } = await db
    .from('companies')
    .select('id')
    .eq('short_code', COMPANY_SHORT_CODE)
    .single()
  if (companyErr || !company) throw new Error(`Could not find Praedium: ${companyErr?.message}`)

  const { data: person, error: personErr } = await db
    .from('people')
    .insert({ full_name: PERSON_NAME })
    .select('id')
    .single()
  if (personErr || !person) throw new Error(`Could not seed person: ${personErr?.message}`)
  seededPersonId = person.id

  const { error: periodErr } = await db.from('employment_periods').insert({
    person_id: person.id,
    company_id: company.id,
    job_title: 'Logistics Lead',
    status: 'active',
    start_date: '2024-03-01',
  })
  if (periodErr) throw new Error(`Could not seed employment period: ${periodErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('schedule departure → offboarding queue → tasks → mark as former', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()

  // Person profile: schedule the departure from the employment row.
  await page.getByRole('link', { name: 'People & access' }).click()
  await page.locator('tr', { hasText: PERSON_NAME }).getByRole('link', { name: PERSON_NAME }).click()
  const empRow = page.locator('.emp-row', { hasText: 'Logistics Lead · Praedium' })
  await expect(empRow.locator('.badge').first()).toHaveText('active')
  await empRow.getByRole('button', { name: 'Schedule departure' }).click()

  const dialog = page.getByRole('dialog')
  await expect(dialog.getByRole('heading', { name: /Schedule .* departure/ })).toBeVisible()
  await dialog.locator('#dep-end').fill(END_DATE)
  await dialog.locator('#dep-last').fill(LAST_WORKING_DATE)
  await dialog.locator('#dep-reason').fill(REASON)
  await dialog.getByRole('button', { name: 'Schedule departure' }).click()

  // The row is now "departing", still active, with the plan linked.
  await expect(empRow).toContainText('Departing')
  await expect(empRow).toContainText(`last day ${LAST_WORKING_DATE}`)
  await expect(empRow.locator('.badge', { hasText: 'active' })).toBeVisible()
  const planLink = page.getByRole('link', { name: 'Open offboarding plan' })
  await expect(planLink).toBeVisible()

  // The database recorded dates, the restricted reason, and one plan.
  const db = serviceClient()
  const { data: period } = await db
    .from('employment_periods')
    .select('id, status, end_date, last_working_date, employment_departure_details(reason)')
    .eq('person_id', seededPersonId)
    .single()
  expect(period?.status).toBe('active')
  expect(period?.end_date).toBe(END_DATE)
  expect(period?.last_working_date).toBe(LAST_WORKING_DATE)
  // One-to-one embed: PostgREST returns an object here, not an array.
  const details = period?.employment_departure_details as { reason: string } | { reason: string }[] | null
  expect(Array.isArray(details) ? details[0]?.reason : details?.reason).toBe(REASON)

  // Directory shows the departing indicator.
  await page.getByRole('link', { name: 'People & access' }).click()
  await expect(page.locator('tr', { hasText: PERSON_NAME })).toContainText('Departing')

  // Offboarding queue: the row with blockers (3 critical template tasks).
  await page.getByRole('link', { name: 'Offboarding', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Offboarding')
  const queueRow = page.locator('.plan-row', { hasText: PERSON_NAME })
  await expect(queueRow).toBeVisible()
  await expect(queueRow).toContainText('Praedium')
  await expect(queueRow).toContainText(LAST_WORKING_DATE)
  await expect(queueRow.locator('.badge')).toHaveText('3 blockers')
  await queueRow.getByRole('link', { name: 'Open plan' }).click()

  // Plan detail is kind-aware: last day, offboarding phases, finish wording.
  await expect(page).toHaveURL(/\/offboarding\/[0-9a-f-]{36}$/)
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  await expect(page.getByText(`last day ${LAST_WORKING_DATE}`)).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Before the last day' })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Last working day' })).toBeVisible()

  // Complete one blocker; two remain. Finishing stays allowed with open tasks.
  const handover = page.locator('.task-row', { hasText: 'Handover documented and accepted' })
  await handover.getByRole('button', { name: 'Complete' }).click()
  await expect(handover.locator('.badge', { hasText: 'done' })).toBeVisible()
  await expect(page.locator('.readiness-badge')).toHaveText('2 blockers')

  await page.getByRole('button', { name: 'Finish offboarding' }).click()
  await confirmDialog(page)
  await expect(page.getByText(/now former/i)).toBeVisible()
  // 5 template tasks, 1 done: the RPC reports every open task, not just blockers.
  await expect(page.getByText(/4 tasks still open/i)).toBeVisible()

  // Person is Former; the plan is completed in the queue.
  await page.getByRole('link', { name: 'Open employee profile' }).click()
  await expect(
    page.locator('.emp-row', { hasText: 'Logistics Lead · Praedium' }).locator('.badge', { hasText: 'former' }),
  ).toBeVisible()
  await page.getByRole('link', { name: 'Offboarding', exact: true }).click()
  await expect(page.locator('.plan-row', { hasText: PERSON_NAME })).toContainText('completed')

  const { data: after } = await db
    .from('employment_periods')
    .select('status, plans(kind, status)')
    .eq('id', period?.id ?? '')
    .single()
  expect(after?.status).toBe('former')
  expect(after?.plans?.[0]?.status).toBe('completed')
})
