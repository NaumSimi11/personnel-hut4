import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Candidate review, part two (plan 018b): schedule an interview with a
 * panel, score it blind (a panel member sees colleagues' scorecards only
 * after submitting their own), build an offer, take it through approval by
 * someone else, extend, accept, and confirm the hire with the agreed start
 * date. Seeds with the service client; cleans up before and after.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const JOB_TITLE = 'E2E Interview Role'
const CANDIDATE_NAME = 'E2E Interview Candidate'
const CANDIDATE_EMAIL = 'e2e-interview-candidate@example.test'
const COLLEAGUE_NAME = 'E2E Interview Colleague'
const START_DATE = '2026-12-01'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let applicationId = ''
let colleagueId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  // The hire creates a person + employment + onboarding plan for the candidate.
  const { data: hired } = await db.from('people').select('id').eq('work_email', CANDIDATE_EMAIL)
  for (const p of hired ?? []) {
    const { data: plans } = await db.from('plans').select('id').eq('person_id', p.id)
    const planIds = (plans ?? []).map((x) => x.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', p.id)
  }
  const { data: jobs } = await db.from('jobs').select('id').eq('title', JOB_TITLE)
  const jobIds = (jobs ?? []).map((j) => j.id)
  if (jobIds.length) {
    const { data: apps } = await db.from('applications').select('id, candidate_id').in('job_id', jobIds)
    const appIds = (apps ?? []).map((a) => a.id)
    if (appIds.length) {
      await db.from('scorecards').delete().in('application_id', appIds)
      await db.from('interviews').delete().in('application_id', appIds)
      await db.from('offers').delete().in('application_id', appIds)
      await db.from('application_events').delete().in('application_id', appIds)
      await db.from('applications').update({ employment_period_id: null }).in('id', appIds)
    }
    for (const p of hired ?? []) await db.from('employment_periods').delete().eq('person_id', p.id)
    await db.from('applications').delete().in('job_id', jobIds)
    const candidateIds = [...new Set((apps ?? []).map((a) => a.candidate_id))]
    if (candidateIds.length) await db.from('candidates').delete().in('id', candidateIds)
    await db.from('jobs').delete().in('id', jobIds)
  }
  for (const p of hired ?? []) await db.from('people').delete().eq('id', p.id)
  await db.from('candidates').delete().eq('email', CANDIDATE_EMAIL)
  await db.from('people').delete().eq('full_name', COLLEAGUE_NAME)
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'SNOW').single()
  if (!company) throw new Error('Snowball not found')
  const { data: job } = await db
    .from('jobs')
    .insert({ company_id: company.id, title: JOB_TITLE, description: 'Interview role', status: 'open' })
    .select('id')
    .single()
  const { data: candidate } = await db
    .from('candidates')
    .insert({ full_name: CANDIDATE_NAME, email: CANDIDATE_EMAIL })
    .select('id')
    .single()
  const { data: app, error } = await db
    .from('applications')
    .insert({ job_id: job!.id, company_id: company.id, candidate_id: candidate!.id, stage_key: 'interview' })
    .select('id')
    .single()
  if (error || !app) throw new Error(`Could not seed application: ${error?.message}`)
  applicationId = app.id
  const { data: colleague } = await db.from('people').insert({ full_name: COLLEAGUE_NAME }).select('id').single()
  colleagueId = colleague!.id
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('interview → blind scorecards → offer approved by someone else → accepted → hired', async ({ page }) => {
  const db = serviceClient()

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)
  await page.goto(`/hiring/applications/${applicationId}`)
  await expect(page.getByRole('heading', { name: CANDIDATE_NAME })).toBeVisible()

  // Schedule a technical interview with the admin and a colleague on the panel.
  const interviews = page.locator('.card', { hasText: 'Interviews' })
  await interviews.getByRole('button', { name: 'Schedule interview' }).click()
  await interviews.locator('#iv-kind').selectOption('technical')
  await interviews.locator('#iv-when').fill('2026-10-05T10:00')
  await interviews.locator('#iv-duration').fill('60')
  await interviews.locator('#iv-location').fill('Meet — link in calendar')
  await interviews.locator('#iv-panel').selectOption([{ label: 'Naum Simidjioski' }, { label: COLLEAGUE_NAME }])
  await interviews.getByRole('button', { name: 'Save interview' }).click()
  const interview = interviews.locator('.interview-card', { hasText: 'Technical' })
  await expect(interview).toBeVisible()
  await expect(interview).toContainText(COLLEAGUE_NAME)

  // The colleague scores first (service role, as them). The admin is on the
  // panel and has not scored, so that card is hidden until they submit.
  const { data: ivRow } = await db.from('interviews').select('id').eq('application_id', applicationId).single()
  await db.from('scorecards').insert({
    interview_id: ivRow!.id,
    application_id: applicationId,
    company_id: (await db.from('applications').select('company_id').eq('id', applicationId).single()).data!.company_id,
    author_id: colleagueId,
    ratings: [{ criterion_id: 'role_skills', label: 'Role skills', rating: 4, evidence: 'Shipped it' }],
    recommendation: 'strong_yes',
    summary: 'Hire.',
  })
  await page.reload()
  await expect(interview.locator('.scorecard-row')).toHaveCount(0)
  await expect(interview).toContainText('hidden until you submit')

  // Submit my scorecard: every criterion rated, a recommendation, a summary.
  await interview.getByRole('button', { name: 'Write scorecard' }).click()
  const form = interview.locator('.scorecard-form')
  for (const [criterion, rating] of [
    ['role_skills', '3'],
    ['problem_solving', '4'],
    ['communication', '3'],
    ['values', '4'],
  ] as const) {
    await form.locator(`input[name="rating-${criterion}"][value="${rating}"]`).check()
  }
  await form.locator('#sc-evidence-role_skills').fill('Walked through a real migration.')
  await form.locator('#sc-recommendation').selectOption('yes')
  await form.locator('#sc-summary').fill('Solid; would want a reference on delivery pace.')
  await form.getByRole('button', { name: 'Submit scorecard' }).click()

  // Now both cards are visible, and the tally shows two recommendations.
  await expect(interview.locator('.scorecard-row')).toHaveCount(2)
  await expect(interview.locator('.scorecard-row', { hasText: COLLEAGUE_NAME })).toContainText('Strong yes')
  await expect(interview.locator('.scorecard-row', { hasText: 'Naum Simidjioski' })).toContainText('Yes')
  await expect(interview.getByRole('button', { name: 'Write scorecard' })).toHaveCount(0)

  // Offer: build terms, submit, cannot approve own; hand authorship to the
  // colleague, approve, extend, accept.
  await page.locator('.decision-panel').getByRole('button', { name: 'Prepare offer' }).click()
  await expect(page.locator('.stage-badge')).toHaveText('offer')
  const offer = page.locator('.offer-card')
  await offer.getByRole('button', { name: 'Draft offer' }).click()
  await offer.locator('#offer-salary').fill('52000')
  await offer.locator('#offer-currency').fill('EUR')
  await offer.locator('#offer-basis').selectOption('annual')
  await offer.locator('#offer-start').fill(START_DATE)
  await offer.locator('#offer-type').selectOption('full_time')
  await offer.getByRole('button', { name: 'Save terms' }).click()
  await expect(offer.locator('.offer-head .badge')).toHaveText('draft')
  await offer.getByRole('button', { name: 'Submit for approval' }).click()
  await expect(offer.locator('.offer-head .badge')).toHaveText('in approval')
  await expect(offer.getByRole('button', { name: 'Approve' })).toHaveCount(0)
  await expect(offer).toContainText('cannot approve')

  // Authorship is immutable (server-set), so hand-off means: withdraw mine,
  // then the colleague drafts theirs (seeded as them, already in approval).
  page.once('dialog', (d) => d.accept('Colleague will own this offer'))
  await offer.getByRole('button', { name: 'Withdraw offer' }).click()
  await expect(offer.getByText('Previous offers (1)')).toBeVisible()
  const { data: appRow } = await db.from('applications').select('company_id').eq('id', applicationId).single()
  await db.from('offers').insert({
    application_id: applicationId,
    company_id: appRow!.company_id,
    terms: { salary: 52000, currency: 'EUR', pay_basis: 'annual', start_date: START_DATE, employment_type: 'full_time' },
    created_by: colleagueId,
    status: 'in_approval',
  })
  await page.reload()
  await offer.getByRole('button', { name: 'Approve' }).click()
  await expect(offer.locator('.offer-head .badge')).toHaveText('approved')
  await offer.getByRole('button', { name: 'Mark as extended' }).click()
  await expect(offer.locator('.offer-head .badge')).toHaveText('extended')
  await offer.getByRole('button', { name: 'Candidate accepted' }).click()
  await expect(offer.locator('.offer-head .badge')).toHaveText('accepted')

  // Confirm hire is prefilled with the agreed start date.
  await page.locator('.decision-panel').getByRole('button', { name: 'Confirm hire' }).click()
  await expect(page.locator('#ch-start')).toHaveValue(START_DATE)
  await page.getByRole('button', { name: 'Complete hire' }).click()
  await expect(page.getByText('Hired. Employment and the onboarding plan were created.')).toBeVisible()
  await page.getByRole('button', { name: 'Done' }).click()
  await expect(page.locator('.stage-badge')).toHaveText('hired')

  const { data: period } = await db
    .from('employment_periods')
    .select('start_date, job_title')
    .eq('id', (await db.from('applications').select('employment_period_id').eq('id', applicationId).single()).data!.employment_period_id!)
    .single()
  expect(period?.start_date).toBe(START_DATE)
  expect(period?.job_title).toBe(JOB_TITLE)
})
