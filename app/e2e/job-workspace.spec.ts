import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Job workspace (plan 017): an approved request becomes a draft job with a
 * tabbed workspace — description + screening questions, channels (careers
 * publish, manual posting record, out-of-date detection), promotion as a
 * separated-duties state machine (advance_promotion, migration 0012), and
 * the activity trail. Runs against the live project; cleans up with the
 * secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const REQUEST_TITLE = 'E2E Workspace Role'
const CANDIDATE_NAME = 'E2E Workspace Candidate'
const CANDIDATE_EMAIL = 'e2e-workspace-candidate@example.test'
const REVIEWER_NAME = 'E2E Workspace Reviewer'
const MANUAL_URL = 'https://jobs.example.test/workspace-role'
const POST_URL = 'https://social.example.test/posts/123'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: jobs } = await db.from('jobs').select('id').eq('title', REQUEST_TITLE)
  const jobIds = (jobs ?? []).map((j) => j.id)
  if (jobIds.length) {
    await db.from('promotions').delete().in('job_id', jobIds)
    const { data: apps } = await db.from('applications').select('id, candidate_id').in('job_id', jobIds)
    const appIds = (apps ?? []).map((a) => a.id)
    if (appIds.length) await db.from('application_events').delete().in('application_id', appIds)
    await db.from('applications').delete().in('job_id', jobIds)
    const candidateIds = [...new Set((apps ?? []).map((a) => a.candidate_id))]
    if (candidateIds.length) await db.from('candidates').delete().in('id', candidateIds)
    await db.from('jobs').delete().in('id', jobIds) // job_channels cascade
  }
  await db.from('candidates').delete().eq('email', CANDIDATE_EMAIL)
  await db.from('hiring_requests').delete().eq('title', REQUEST_TITLE)
  await db.from('people').delete().eq('full_name', REVIEWER_NAME)
}

let reviewerId = ''

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'SNOW').single()
  if (!company) throw new Error('Snowball not found')
  const { error } = await db.from('hiring_requests').insert({
    company_id: company.id,
    title: REQUEST_TITLE,
    headcount: 2,
    status: 'approved',
    requested_by: null,
  })
  if (error) throw new Error(`Could not seed request: ${error.message}`)
  const { data: reviewer, error: reviewerErr } = await db
    .from('people')
    .insert({ full_name: REVIEWER_NAME })
    .select('id')
    .single()
  if (reviewerErr || !reviewer) throw new Error(`Could not seed reviewer: ${reviewerErr?.message}`)
  reviewerId = reviewer.id
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('prepare job → describe → publish channels → promote → applications → activity', async ({ page }) => {
  const db = serviceClient()

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()

  // 01 → a draft job with the workspace tabs and the stepper on step 01.
  await page.getByRole('link', { name: 'Hiring' }).click()
  await page.locator('.request-row', { hasText: REQUEST_TITLE }).getByRole('button', { name: 'Prepare job' }).click()
  await expect(page.getByRole('heading', { name: REQUEST_TITLE })).toBeVisible()
  await expect(page.locator('.page-head .badge')).toHaveText('draft')
  await expect(page.locator('.step.current')).toContainText('Hiring request')
  const jobId = page.url().split('/').pop() ?? ''

  // 02 — description + screening questions bump the revision; then Mark ready.
  await page.getByRole('tab', { name: 'Description' }).click()
  await page.locator('#job-description').fill('Own the warehouse schedule and supplier handovers.')
  await page.getByRole('button', { name: 'Add question' }).click()
  await page.locator('.question-row').first().locator('.question-prompt').fill('Why this role?')
  await page.getByRole('button', { name: 'Add question' }).click()
  const second = page.locator('.question-row').nth(1)
  await second.locator('.question-prompt').fill('Eligible to work in North Macedonia?')
  await second.locator('.question-kind').selectOption('yes_no')
  await page.getByRole('button', { name: 'Save description' }).click()
  await expect(page.getByText('Description saved')).toBeVisible()

  const { data: afterSave } = await db
    .from('jobs')
    .select('description_revision, screening_questions')
    .eq('id', jobId)
    .single()
  expect(afterSave?.description_revision).toBe(2)
  expect((afterSave?.screening_questions as unknown[]).length).toBe(2)

  await page.getByRole('tab', { name: 'Overview' }).click()
  await page.getByRole('button', { name: 'Mark ready' }).click()
  await expect(page.locator('.page-head .badge')).toHaveText('ready')
  await expect(page.locator('.step.current')).toContainText('Job ready')

  // 03 — publish the careers listing (opens the job) and record a manual posting.
  await page.getByRole('tab', { name: 'Channels' }).click()
  const careers = page.locator('.channel-row', { hasText: 'Company careers page' })
  await careers.getByRole('button', { name: 'Publish' }).click()
  await expect(careers.locator('.badge')).toHaveText('live')
  await expect(page.locator('.page-head .badge')).toHaveText('open')
  await expect(page.locator('.step.current')).toContainText('Published')

  const manual = page.locator('.channel-row', { hasText: 'Other platform' })
  await manual.getByRole('button', { name: 'Record posting' }).click()
  await manual.locator('#manual-url').fill(MANUAL_URL)
  await manual.getByRole('button', { name: 'Save posting' }).click()
  await expect(manual.locator('.badge')).toHaveText('submitted')
  await expect(manual.getByRole('link', { name: /jobs\.example\.test/ })).toHaveAttribute('href', MANUAL_URL)

  const linkedin = page.locator('.channel-row', { hasText: 'LinkedIn' })
  await expect(linkedin).toContainText('Not connected')

  // Editing the description again flags the live listing as out of date.
  await page.getByRole('tab', { name: 'Description' }).click()
  await page.locator('#job-description').fill('Own the warehouse schedule, supplier handovers and the seasonal team.')
  await page.getByRole('button', { name: 'Save description' }).click()
  await expect(page.getByText('Description saved')).toBeVisible()
  await page.getByRole('tab', { name: 'Channels' }).click()
  await expect(careers).toContainText('Out of date')

  // Promotion — request, draft, submit; the drafter cannot review their own work.
  await page.getByRole('tab', { name: 'Promotion' }).click()
  await page.getByRole('button', { name: 'Request promotion' }).click()
  const promo = page.locator('.promotion-card', { hasText: 'LinkedIn' })
  await expect(promo.locator('.badge')).toHaveText('requested')
  await expect(promo).toContainText(REQUEST_TITLE) // the brief snapshot
  await promo.locator('textarea.copy').fill('Snowball is hiring a Workspace Role — join a team that ships.')
  await promo.getByRole('button', { name: 'Save draft' }).click()
  await expect(promo.locator('.badge')).toHaveText('draft')
  await promo.getByRole('button', { name: 'Submit for review' }).click()
  await expect(promo.locator('.badge')).toHaveText('in review')
  await expect(promo.getByRole('button', { name: 'Approve' })).toHaveCount(0)
  await expect(promo).toContainText('cannot review')

  // Hand the draft to another person (service role) so the admin can review it.
  const { data: promoRow } = await db.from('promotions').select('id').eq('job_id', jobId).single()
  await db.from('promotions').update({ drafted_by: reviewerId }).eq('id', promoRow?.id ?? '')
  await page.reload()
  await page.getByRole('tab', { name: 'Promotion' }).click()
  await promo.getByRole('button', { name: 'Approve' }).click()
  await expect(promo.locator('.badge')).toHaveText('approved')
  await promo.locator('.publish-form input').fill(POST_URL)
  await promo.getByRole('button', { name: 'Record publication' }).click()
  await expect(promo.locator('.badge')).toHaveText('published')
  await expect(promo.getByRole('link', { name: /social\.example\.test/ })).toHaveAttribute('href', POST_URL)

  // 04 — a candidate added by hand moves the journey on.
  await page.getByRole('tab', { name: 'Applications' }).click()
  await page.getByRole('button', { name: 'Add candidate' }).click()
  await page.locator('#ac-name').fill(CANDIDATE_NAME)
  await page.locator('#ac-email').fill(CANDIDATE_EMAIL)
  await page.getByRole('button', { name: 'Save candidate' }).click()
  await expect(page.locator('.application-row', { hasText: CANDIDATE_NAME })).toBeVisible()
  await expect(page.locator('.step.current')).toContainText('Applications')

  // Activity — the trail covers the job, its channels, the promotion and the application.
  await page.getByRole('tab', { name: 'Activity' }).click()
  const activity = page.locator('.activity-row')
  await expect(activity.filter({ hasText: 'Job' }).first()).toBeVisible()
  await expect(activity.filter({ hasText: 'Channel' }).first()).toBeVisible()
  await expect(activity.filter({ hasText: 'Promotion' }).first()).toBeVisible()
  await expect(activity.filter({ hasText: 'Application' }).first()).toBeVisible()
})
