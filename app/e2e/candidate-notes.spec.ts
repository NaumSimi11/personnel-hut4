import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Candidate notes and the imported Zoho history (plan 055). First half: a
 * pool holder (the admin) opens a pool candidate's record, sees the empty
 * Notes card, adds a note, sees it with their name and today's date, the
 * row lands as kind 'note' with no company and the admin as actor, and
 * Remove takes it away again. Second half: an application with an
 * imported-style interview (provider zoho_recruit, the Zoho name, outcome
 * and an unresolved interviewer in custom.zoho) and a scorecard whose
 * author is a name only (author_id null) renders on the application page
 * with the import line, the unresolved name after the panel and the
 * reviewer's name on the card. Seeds with the service client; cleans
 * before and after.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const JOB_TITLE = 'E2E Notes Role'
const PERSON_NAME = 'E2E Notes Person'
const PERSON_EMAIL = 'e2e-notes@example.test'
const PROVIDER = 'e2e'
const PROVIDER_REF = 'notes-1'
const NOTE_BODY = 'E2E: called, voicemail'
const ZOHO_PROVIDER = 'zoho_recruit'
const INTERVIEW_REF = 'e2e-iv-1'
const REVIEW_REF = 'e2e-rv-1'
const INTERVIEW_NAME = 'Level 1 Interview'
const INTERVIEW_OUTCOME = 'Move to next round'
const UNRESOLVED_INTERVIEWER = 'E2E Unresolved'
const REVIEWER_NAME = 'E2E Reviewer'
const INTERVIEW_AT = '2026-09-01T10:00:00Z'

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/** The app's longDate for "now": UTC, like the database's now(). */
function todayLong(): string {
  const d = new Date()
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`
}

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

type Db = ReturnType<typeof serviceClient>

let jobId = ''
let candidateId = ''
let applicationId = ''

async function deleteApplications(db: Db, appIds: string[]): Promise<void> {
  if (!appIds.length) return
  const { data: interviews } = await db.from('interviews').select('id').in('application_id', appIds)
  const interviewIds = (interviews ?? []).map((i) => i.id)
  await db.from('scorecards').delete().in('application_id', appIds)
  if (interviewIds.length) await db.from('interview_panel').delete().in('interview_id', interviewIds)
  await db.from('interviews').delete().in('application_id', appIds)
  await db.from('application_events').delete().in('application_id', appIds)
  await db.from('applications').delete().in('id', appIds)
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  // Imported-style rows by their refs, in case the candidate is already gone.
  await db.from('scorecards').delete().eq('provider', ZOHO_PROVIDER).eq('provider_ref', REVIEW_REF)
  await db.from('interviews').delete().eq('provider', ZOHO_PROVIDER).eq('provider_ref', INTERVIEW_REF)
  const { data: byName } = await db.from('candidates').select('id').eq('full_name', PERSON_NAME)
  const { data: byEmail } = await db.from('candidates').select('id').eq('email', PERSON_EMAIL)
  const { data: byRef } = await db.from('candidates').select('id').eq('provider', PROVIDER).eq('provider_ref', PROVIDER_REF)
  const candidateIds = [...new Set([...(byName ?? []), ...(byEmail ?? []), ...(byRef ?? [])].map((c) => c.id))]
  if (candidateIds.length) {
    const { data: apps } = await db.from('applications').select('id').in('candidate_id', candidateIds)
    await deleteApplications(db, (apps ?? []).map((a) => a.id))
    // Notes cascade with the candidate; deleted explicitly so nothing is left to chance.
    await db.from('candidate_notes').delete().in('candidate_id', candidateIds)
    await db.from('candidates').delete().in('id', candidateIds)
  }
  const { data: jobs } = await db.from('jobs').select('id').eq('title', JOB_TITLE)
  const jobIds = (jobs ?? []).map((j) => j.id)
  if (jobIds.length) {
    const { data: apps } = await db.from('applications').select('id').in('job_id', jobIds)
    await deleteApplications(db, (apps ?? []).map((a) => a.id))
    await db.from('jobs').delete().in('id', jobIds)
  }
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'SNOW').single()
  if (!company) throw new Error('Snowball not found')
  const { data: job, error: jobErr } = await db
    .from('jobs')
    .insert({ company_id: company.id, title: JOB_TITLE, description: 'Notes role', status: 'open' })
    .select('id')
    .single()
  if (jobErr || !job) throw new Error(`Could not seed job: ${jobErr?.message}`)
  jobId = job.id

  // A provider-keyed pool record (the service client passes the guards).
  const { data: candidate, error: candErr } = await db
    .from('candidates')
    .insert({
      full_name: PERSON_NAME,
      email: PERSON_EMAIL,
      provider: PROVIDER,
      provider_ref: PROVIDER_REF,
      source_key: 'head_hunt',
      current_title: 'Warehouse lead',
    })
    .select('id')
    .single()
  if (candErr || !candidate) throw new Error(`Could not seed candidate: ${candErr?.message}`)
  candidateId = candidate.id

  const { data: application, error: appErr } = await db
    .from('applications')
    .insert({
      job_id: jobId,
      company_id: company.id,
      candidate_id: candidateId,
      stage_key: 'interview',
      source_key: 'head_hunt',
    })
    .select('id')
    .single()
  if (appErr || !application) throw new Error(`Could not seed application: ${appErr?.message}`)
  applicationId = application.id

  // One imported-style interview (D3): company_id is derived by trigger.
  const { data: interview, error: ivErr } = await db
    .from('interviews')
    .insert({
      application_id: applicationId,
      kind: 'other',
      scheduled_at: INTERVIEW_AT,
      duration_minutes: 60,
      location: 'Zoho Recruit',
      status: 'completed',
      provider: ZOHO_PROVIDER,
      provider_ref: INTERVIEW_REF,
      custom: { zoho: { name: INTERVIEW_NAME, outcome: INTERVIEW_OUTCOME, interviewers: [UNRESOLVED_INTERVIEWER] } },
    })
    .select('id')
    .single()
  if (ivErr || !interview) throw new Error(`Could not seed interview: ${ivErr?.message}`)

  // A review by someone we could not link (D4): a name, no author_id;
  // application_id / company_id are derived by trigger.
  const { error: rvErr } = await db.from('scorecards').insert({
    interview_id: interview.id,
    ratings: [{ criterion_id: 'zoho_overall', label: 'Overall (Zoho Recruit)', rating: 4, evidence: '' }],
    recommendation: 'strong_yes',
    summary: 'E2E: strong candidate',
    author_id: null,
    author_name: REVIEWER_NAME,
    provider: ZOHO_PROVIDER,
    provider_ref: REVIEW_REF,
  })
  if (rvErr) throw new Error(`Could not seed scorecard: ${rvErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('a note on the record → shown with author and date → removed; an imported interview with a named-only reviewer renders on the application', async ({
  page,
}) => {
  const db = serviceClient()
  const { data: admin } = await db.from('people').select('id, full_name').ilike('work_email', ADMIN_EMAIL).single()
  expect(admin?.id).toBeTruthy()
  expect(admin?.full_name).toBeTruthy()

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // The record: the Notes card, empty.
  await page.goto(`/hiring/candidates/${candidateId}`)
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  const notes = page.getByTestId('candidate-notes')
  await expect(notes).toBeVisible()
  await expect(notes).toContainText('No notes yet.')

  // Add a note: the row shows with the admin's name and today.
  await notes.locator('#note-body').fill(NOTE_BODY)
  await notes.getByTestId('note-add').click()
  await expect(notes).toContainText(NOTE_BODY)
  await expect(notes).not.toContainText('No notes yet.')
  await expect(notes.locator('#note-body')).toHaveValue('')

  const { data: rows } = await db
    .from('candidate_notes')
    .select('id, kind, body, company_id, actor_id, actor_name, provider')
    .eq('candidate_id', candidateId)
  expect(rows).toHaveLength(1)
  const note = rows![0]!
  expect(note.kind).toBe('note')
  expect(note.body).toBe(NOTE_BODY)
  expect(note.company_id).toBeNull()
  expect(note.actor_id).toBe(admin!.id)
  expect(note.actor_name).toBeNull()
  expect(note.provider).toBeNull()

  const row = notes.getByTestId(`note-${note.id}`)
  await expect(row).toBeVisible()
  await expect(row).toContainText('Note')
  await expect(row).toContainText(NOTE_BODY)
  await expect(row).toContainText(`${admin!.full_name} · ${todayLong()}`)

  // Remove it (own note): the app's confirm dialog, then gone on both ends.
  await row.getByTestId(`note-remove-${note.id}`).click()
  await confirmDialog(page)
  await expect(row).toBeHidden()
  await expect(notes).toContainText('No notes yet.')
  const { count: after } = await db
    .from('candidate_notes')
    .select('id', { count: 'exact', head: true })
    .eq('candidate_id', candidateId)
  expect(after).toBe(0)

  // The application page: the imported interview and its named-only review.
  await page.goto(`/hiring/applications/${applicationId}`)
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  const interviews = page.locator('#candidate-interviews')
  await expect(interviews).toBeVisible()
  const imported = interviews.getByTestId('interview-imported')
  await expect(imported).toHaveCount(1)
  await expect(imported).toHaveText(`Imported from Zoho Recruit · ${INTERVIEW_NAME} · outcome: ${INTERVIEW_OUTCOME}`)
  const interview = interviews.locator('.interview-card', { hasText: INTERVIEW_NAME })
  await expect(interview).toContainText('Other')
  await expect(interview).toContainText('completed')
  await expect(interview).toContainText(`Also on the panel: ${UNRESOLVED_INTERVIEWER}`)
  const scorecard = interview.locator('.scorecard-row')
  await expect(scorecard).toHaveCount(1)
  await expect(scorecard.locator('strong').first()).toHaveText(REVIEWER_NAME)
  await expect(scorecard).toContainText('Strong yes')
  await expect(scorecard).toContainText('Overall (Zoho Recruit)')
})
