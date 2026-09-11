import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Onboarding workspace: every confirmed hire already gets an onboarding plan
 * with dated tasks (`public.confirm_hire`, migration 0009); this spec seeds
 * one deterministically (not through the hiring flow) and drives the queue +
 * plan detail screens through block/complete/finish. Runs against the live
 * Supabase project; cleans up with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON_NAME = 'E2E Onboarding Starter'
const COMPANY_SHORT_CODE = 'SNOW'

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

const START_DATE = daysFromNow(7)

async function cleanup(): Promise<void> {
  const db = serviceClient()

  // 1. plan_tasks (by plan ids), 2. plans (by person id),
  // 3. employment_periods (by person id), 4. people (full_name = constant).
  const { data: person } = await db
    .from('people')
    .select('id')
    .eq('full_name', PERSON_NAME)
    .maybeSingle()
  if (person) {
    const { data: plans } = await db.from('plans').select('id').eq('person_id', person.id)
    const planIds = (plans ?? []).map((p) => p.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', person.id)
    await db.from('employment_periods').delete().eq('person_id', person.id)
  }
  await db.from('people').delete().eq('full_name', PERSON_NAME)
}

async function seed(): Promise<void> {
  const db = serviceClient()

  const { data: company, error: companyErr } = await db
    .from('companies')
    .select('id')
    .eq('short_code', COMPANY_SHORT_CODE)
    .single()
  if (companyErr || !company) {
    throw new Error(`Could not find Snowball company: ${companyErr?.message}`)
  }

  const { data: person, error: personErr } = await db
    .from('people')
    .insert({ full_name: PERSON_NAME })
    .select('id')
    .single()
  if (personErr || !person) throw new Error(`Could not seed person: ${personErr?.message}`)

  const { data: period, error: periodErr } = await db
    .from('employment_periods')
    .insert({
      person_id: person.id,
      company_id: company.id,
      job_title: 'Starter',
      status: 'pre_start',
      start_date: START_DATE,
    })
    .select('id')
    .single()
  if (periodErr || !period) {
    throw new Error(`Could not seed employment period: ${periodErr?.message}`)
  }

  const { data: plan, error: planErr } = await db
    .from('plans')
    .insert({
      kind: 'onboarding',
      person_id: person.id,
      company_id: company.id,
      employment_period_id: period.id,
      start_date: START_DATE,
      status: 'in_progress',
    })
    .select('id')
    .single()
  if (planErr || !plan) throw new Error(`Could not seed plan: ${planErr?.message}`)

  const { error: tasksErr } = await db.from('plan_tasks').insert([
    {
      plan_id: plan.id,
      title: 'E2E Documents reviewed',
      owner_role: 'hr',
      phase_key: 'before_start',
      critical: true,
      sort_order: 10,
      status: 'open',
    },
    {
      plan_id: plan.id,
      title: 'E2E Laptop handed over',
      owner_role: 'it',
      phase_key: 'before_start',
      critical: true,
      sort_order: 20,
      status: 'open',
    },
    {
      plan_id: plan.id,
      title: 'E2E Team introduction',
      owner_role: 'manager',
      phase_key: 'day_one',
      critical: false,
      sort_order: 30,
      status: 'open',
    },
  ])
  if (tasksErr) throw new Error(`Could not seed plan tasks: ${tasksErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('onboarding queue → plan → block/complete/finish', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()

  // Step 1: the seeded plan shows up with two open critical tasks.
  await page.getByRole('link', { name: 'Onboarding', exact: true }).click()
  const planRow = page.locator('.plan-row', { hasText: PERSON_NAME })
  await expect(planRow).toBeVisible()
  await expect(planRow.locator('.badge')).toHaveText('2 readiness gaps')

  // Step 2: open the plan; three task rows and both phase headings appear.
  await planRow.getByRole('link', { name: 'Open plan' }).click()
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  await expect(page.locator('.task-row', { hasText: 'E2E Documents reviewed' })).toBeVisible()
  await expect(page.locator('.task-row', { hasText: 'E2E Laptop handed over' })).toBeVisible()
  await expect(page.locator('.task-row', { hasText: 'E2E Team introduction' })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Before start' })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Day one' })).toBeVisible()

  // Step 3: block the laptop task; readiness is unaffected (still open, just blocked).
  const laptopRow = page.locator('.task-row', { hasText: 'E2E Laptop handed over' })
  page.once('dialog', (dialog) => dialog.accept('Supplier delay'))
  await laptopRow.getByRole('button', { name: 'Block' }).click()
  await expect(laptopRow.locator('.badge', { hasText: 'blocked' })).toBeVisible()
  await expect(laptopRow).toContainText('Supplier delay')
  await expect(page.locator('.page-head .badge')).toHaveText('2 readiness gaps')

  // Step 4: mark both critical tasks complete; readiness flips, the
  // non-critical task is left open.
  const docsRow = page.locator('.task-row', { hasText: 'E2E Documents reviewed' })
  await docsRow.getByRole('button', { name: 'Mark complete' }).click()
  await expect(docsRow.locator('.badge', { hasText: 'done' })).toBeVisible()
  await laptopRow.getByRole('button', { name: 'Mark complete' }).click()
  await expect(laptopRow.locator('.badge', { hasText: 'done' })).toBeVisible()
  await expect(page.locator('.page-head .badge')).toHaveText('Ready for day one')
  const teamRow = page.locator('.task-row', { hasText: 'E2E Team introduction' })
  await expect(teamRow.locator('.badge', { hasText: 'open' })).toBeVisible()

  // Step 5: finish onboarding.
  await page.getByRole('button', { name: 'Finish onboarding' }).click()
  await expect(page.getByText('Onboarding marked complete.')).toBeVisible()
  await expect(page.locator('.footer-card .badge.green')).toContainText('Completed')

  // Step 6: back on the queue, the plan is no longer "In progress".
  await page.getByRole('link', { name: 'Onboarding', exact: true }).click()
  await expect(page.locator('.in-progress-section')).not.toContainText(PERSON_NAME)
})
