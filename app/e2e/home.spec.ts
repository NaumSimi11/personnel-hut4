import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Overview: the "needs a decision" queue merges hiring requests awaiting a
 * decision, applications at offer, and onboarding plans with open critical
 * tasks (plan 012). This spec seeds one of each deterministically and drives
 * the queue + drill-down links. Runs against the live Supabase project;
 * cleans up with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const COMPANY_SHORT_CODE = 'SNOW'

const REQUEST_TITLE = 'E2E Home Request'
const CANDIDATE_NAME = 'E2E Home Candidate'
const CANDIDATE_EMAIL = 'e2e-home-candidate@example.test'
const JOB_TITLE = 'E2E Home Job'
const PERSON_NAME = 'E2E Home Starter'
const TASK_TITLE = 'E2E Home Critical Task'

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

  // 1. plan_tasks (by plan ids) → 2. plans (by person id) →
  // 3. employment_periods (by person id) → 4. people (by full_name).
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

  // 5. applications (by candidate id) → 6. candidates (by email) →
  // 7. jobs (by title) → 8. hiring_requests (by title).
  const { data: candidate } = await db
    .from('candidates')
    .select('id')
    .eq('email', CANDIDATE_EMAIL)
    .maybeSingle()
  if (candidate) await db.from('applications').delete().eq('candidate_id', candidate.id)
  await db.from('candidates').delete().eq('email', CANDIDATE_EMAIL)
  await db.from('jobs').delete().eq('title', JOB_TITLE)
  await db.from('hiring_requests').delete().eq('title', REQUEST_TITLE)
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

  const { error: reqErr } = await db.from('hiring_requests').insert({
    company_id: company.id,
    title: REQUEST_TITLE,
    status: 'submitted',
    requested_by: null,
  })
  if (reqErr) throw new Error(`Could not seed hiring request: ${reqErr.message}`)

  const { data: job, error: jobErr } = await db
    .from('jobs')
    .insert({ company_id: company.id, title: JOB_TITLE, status: 'open' })
    .select('id')
    .single()
  if (jobErr || !job) throw new Error(`Could not seed job: ${jobErr?.message}`)

  const { data: candidate, error: candErr } = await db
    .from('candidates')
    .insert({ full_name: CANDIDATE_NAME, email: CANDIDATE_EMAIL })
    .select('id')
    .single()
  if (candErr || !candidate) throw new Error(`Could not seed candidate: ${candErr?.message}`)

  const { error: appErr } = await db.from('applications').insert({
    job_id: job.id,
    company_id: company.id,
    candidate_id: candidate.id,
    stage_key: 'offer',
  })
  if (appErr) throw new Error(`Could not seed application: ${appErr.message}`)

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

  const { error: taskErr } = await db.from('plan_tasks').insert({
    plan_id: plan.id,
    title: TASK_TITLE,
    owner_role: 'hr',
    phase_key: 'before_start',
    critical: true,
    status: 'open',
    sort_order: 10,
  })
  if (taskErr) throw new Error(`Could not seed plan task: ${taskErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('overview queue merges hiring, offer, and onboarding rows', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()

  await page.getByRole('link', { name: 'Overview', exact: true }).click()

  const queueCard = page.locator('.queue-card')
  await expect(queueCard).toContainText(REQUEST_TITLE)
  await expect(queueCard).toContainText(`Offer: ${CANDIDATE_NAME}`)
  await expect(queueCard).toContainText(`Onboarding: ${PERSON_NAME}`)

  // Onboarding row → plan page shows the seeded critical task.
  const onboardingRow = queueCard.locator('.queue-row', {
    hasText: `Onboarding: ${PERSON_NAME}`,
  })
  await onboardingRow.getByRole('link', { name: 'Open plan' }).click()
  await expect(page).toHaveURL(/\/onboarding\//)
  await expect(page.locator('.task-row', { hasText: TASK_TITLE })).toBeVisible()

  // Back to Overview → offer row → job page shows the seeded job.
  await page.getByRole('link', { name: 'Overview', exact: true }).click()
  const offerRow = page.locator('.queue-card').locator('.queue-row', {
    hasText: `Offer: ${CANDIDATE_NAME}`,
  })
  await offerRow.getByRole('link', { name: 'Open job' }).click()
  await expect(page.getByRole('heading', { name: JOB_TITLE })).toBeVisible()

  // Back to Overview → metrics tiles render numbers (live data varies, so
  // only the shape is asserted).
  await page.getByRole('link', { name: 'Overview', exact: true }).click()
  const hiringTile = page.locator('.metric-tile', { hasText: 'Hiring requests' })
  await expect(hiringTile.locator('.metric-value')).toHaveText(/^\d+$/)
})
