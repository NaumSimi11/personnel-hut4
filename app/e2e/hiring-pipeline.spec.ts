import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Hiring workspace part B: an approved request becomes a job, a candidate
 * moves through the pipeline stage by stage, and confirm hire turns them
 * into an employee with an onboarding plan via the atomic `confirm_hire` RPC
 * (migration 0009). Runs against the live Supabase project; cleans up with
 * the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const REQUEST_TITLE = 'E2E Pipeline Role'
const CANDIDATE_NAME = 'E2E Pipeline Candidate'
const CANDIDATE_EMAIL = 'e2e-pipeline-candidate@example.test'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function cleanup(): Promise<void> {
  const db = serviceClient()

  // 1. plan_tasks + plans for the employment period this test's hire creates.
  // The hire puts the candidate's email on the record as personal (plan 046).
  const { data: matches } = await db
    .from('people')
    .select('id')
    .or(`work_email.eq.${CANDIDATE_EMAIL},personal_email.eq.${CANDIDATE_EMAIL}`)
  for (const person of matches ?? []) {
    const { data: periods } = await db
      .from('employment_periods')
      .select('id')
      .eq('person_id', person.id)
    const periodIds = (periods ?? []).map((p) => p.id)
    if (periodIds.length) {
      const { data: plans } = await db.from('plans').select('id').in('employment_period_id', periodIds)
      const planIds = (plans ?? []).map((p) => p.id)
      if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
      await db.from('plans').delete().in('employment_period_id', periodIds)
    }
  }

  // 2. application_events, applications, candidates by name/email.
  const { data: byName } = await db.from('candidates').select('id').eq('full_name', CANDIDATE_NAME)
  const { data: byEmail } = await db.from('candidates').select('id').eq('email', CANDIDATE_EMAIL)
  const candidateIds = [...new Set([...(byName ?? []), ...(byEmail ?? [])].map((c) => c.id))]
  if (candidateIds.length) {
    const { data: apps } = await db.from('applications').select('id').in('candidate_id', candidateIds)
    const appIds = (apps ?? []).map((a) => a.id)
    if (appIds.length) await db.from('application_events').delete().in('application_id', appIds)
    await db.from('applications').delete().in('candidate_id', candidateIds)
    await db.from('candidates').delete().in('id', candidateIds)
  }

  // 3. employment_periods + people by either email.
  for (const person of matches ?? []) {
    await db.from('employment_periods').delete().eq('person_id', person.id)
    await db.from('people').delete().eq('id', person.id)
  }

  // 4. jobs by title.
  await db.from('jobs').delete().eq('title', REQUEST_TITLE)

  // 5. hiring_requests by title.
  await db.from('hiring_requests').delete().eq('title', REQUEST_TITLE)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
})

test.afterAll(async () => {
  await cleanup()
})

test('approved request → prepare job → candidate pipeline → confirm hire', async ({ page }) => {
  const db = serviceClient()
  const { data: company, error: companyErr } = await db
    .from('companies')
    .select('id')
    .eq('short_code', 'SNOW')
    .single()
  expect(companyErr).toBeNull()
  expect(company?.id).toBeTruthy()

  // Step 1: service-insert an already-approved request (service role bypasses
  // the decision-transition gate, same as the sibling hiring-requests spec).
  const { error: insertErr } = await db.from('hiring_requests').insert({
    company_id: company!.id,
    title: REQUEST_TITLE,
    headcount: 1,
    status: 'approved',
    requested_by: null,
  })
  expect(insertErr).toBeNull()

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()

  // Step 2: the approved row shows Prepare job; clicking it lands on the job page.
  await page.getByRole('link', { name: 'Hiring' }).click()
  const requestRow = page.locator('.request-row', { hasText: REQUEST_TITLE })
  await expect(requestRow).toBeVisible()
  await requestRow.getByRole('button', { name: 'Prepare job' }).click()

  await expect(page.getByRole('heading', { name: REQUEST_TITLE })).toBeVisible()
  // A prepared job starts as a draft (plan 017); publishing a channel opens it.
  await expect(page.locator('.page-head .badge')).toHaveText('draft')

  // Step 3: add the candidate; the application row appears at stage `new`.
  await page.getByRole('tab', { name: 'Applications' }).click()
  await page.getByRole('button', { name: 'Add candidate' }).click()
  await page.locator('#ac-name').fill(CANDIDATE_NAME)
  await page.locator('#ac-email').fill(CANDIDATE_EMAIL)
  await page.getByRole('button', { name: 'Save candidate' }).click()

  const appRow = page.locator('.application-row', { hasText: CANDIDATE_NAME })
  await expect(appRow).toBeVisible()
  await expect(appRow.locator('.badge')).toHaveText('new')

  // Step 4: advance new -> screening -> interview -> offer.
  await appRow.getByRole('button', { name: 'Move to screening' }).click()
  await expect(appRow.locator('.badge')).toHaveText('screening')
  await appRow.getByRole('button', { name: 'Move to interview' }).click()
  await expect(appRow.locator('.badge')).toHaveText('interview')
  await appRow.getByRole('button', { name: 'Prepare offer' }).click()
  await expect(appRow.locator('.badge')).toHaveText('offer')
  await expect(appRow.locator('.badge')).toHaveClass(/amber/)

  // Step 5: confirm hire, keeping the prefilled name/position/start date.
  await appRow.getByRole('button', { name: 'Confirm hire' }).click()
  const hire = page.getByTestId('add-employee-dialog')
  await expect(hire.locator('#ae-title')).toHaveValue(REQUEST_TITLE)
  await hire.getByRole('button', { name: 'Complete hire' }).click()
  await expect(hire.getByRole('heading', { name: /Hired\. Employment recorded, the onboarding checklist started/ })).toBeVisible()
  await hire.getByRole('button', { name: 'Done' }).click()

  await expect(appRow.locator('.badge')).toHaveText('hired')
  await expect(appRow.getByRole('link', { name: 'Open employee profile' })).toBeVisible()

  // Step 6: the new employee shows up in the directory. NOTE: the employee's
  // name is the confirm-dialog full name, prefilled with the candidate name.
  await page.getByRole('link', { name: 'People & access' }).click()
  const dirRow = page.locator('tr', { hasText: CANDIDATE_NAME })
  await expect(dirRow).toBeVisible()
  await expect(dirRow).toContainText('Snowball')
  await expect(dirRow).toContainText(REQUEST_TITLE)
  await expect(dirRow.locator('.badge')).toHaveText('active')

  // Step 7: employment history on the profile, and the onboarding plan
  // created alongside it (asserted directly via the service client).
  await dirRow.locator('.person-link').click()
  await expect(page.getByRole('heading', { name: CANDIDATE_NAME })).toBeVisible()
  await expect(page.locator('.emp-row', { hasText: REQUEST_TITLE })).toBeVisible()

  // The candidate applied from a personal address; it stays personal on the record.
  const { data: hiredPerson, error: personErr } = await db
    .from('people')
    .select('id')
    .eq('personal_email', CANDIDATE_EMAIL)
    .single()
  expect(personErr).toBeNull()
  expect(hiredPerson?.id).toBeTruthy()

  const { data: period, error: periodErr } = await db
    .from('employment_periods')
    .select('id')
    .eq('person_id', hiredPerson!.id)
    .single()
  expect(periodErr).toBeNull()
  expect(period?.id).toBeTruthy()

  const { data: plan, error: planErr } = await db
    .from('plans')
    .select('id')
    .eq('employment_period_id', period!.id)
    .eq('kind', 'onboarding')
    .single()
  expect(planErr).toBeNull()
  expect(plan?.id).toBeTruthy()

  const { data: tasks, error: tasksErr } = await db
    .from('plan_tasks')
    .select('id')
    .eq('plan_id', plan!.id)
  expect(tasksErr).toBeNull()
  expect(tasks?.length).toBe(5)
})
