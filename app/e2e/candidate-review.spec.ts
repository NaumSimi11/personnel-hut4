import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Candidate review, part one (plan 018a): the candidate page gathers the
 * application's material — files in a private bucket behind signed links,
 * answers to the job's screening questions, notes and stage history — and
 * the decision panel records owner, next action and a reasoned rejection.
 * Seeds a job with questions and one application with the service client;
 * cleans up rows and objects before and after.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const JOB_TITLE = 'E2E Review Role'
const CANDIDATE_NAME = 'E2E Review Candidate'
const CANDIDATE_EMAIL = 'e2e-review-candidate@example.test'

// Smallest valid PDF: one empty page.
const PDF = Buffer.from(
  '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000052 00000 n \n0000000101 00000 n \ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n160\n%%EOF\n',
)

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let applicationId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: jobs } = await db.from('jobs').select('id').eq('title', JOB_TITLE)
  const jobIds = (jobs ?? []).map((j) => j.id)
  if (jobIds.length) {
    const { data: apps } = await db.from('applications').select('id, candidate_id').in('job_id', jobIds)
    for (const a of apps ?? []) {
      const { data: objects } = await db.storage.from('candidate-files').list(a.id)
      const paths = (objects ?? []).map((o) => `${a.id}/${o.name}`)
      if (paths.length) await db.storage.from('candidate-files').remove(paths)
    }
    const appIds = (apps ?? []).map((a) => a.id)
    if (appIds.length) {
      await db.from('application_files').delete().in('application_id', appIds)
      await db.from('application_events').delete().in('application_id', appIds)
    }
    await db.from('applications').delete().in('job_id', jobIds)
    const candidateIds = [...new Set((apps ?? []).map((a) => a.candidate_id))]
    if (candidateIds.length) await db.from('candidates').delete().in('id', candidateIds)
    await db.from('jobs').delete().in('id', jobIds)
  }
  await db.from('candidates').delete().eq('email', CANDIDATE_EMAIL)
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'SNOW').single()
  if (!company) throw new Error('Snowball not found')
  const { data: job, error: jobErr } = await db
    .from('jobs')
    .insert({
      company_id: company.id,
      title: JOB_TITLE,
      description: 'Review role',
      status: 'open',
      screening_questions: [
        { id: 'q-why', prompt: 'Why this role?', kind: 'text', required: true },
        { id: 'q-eligible', prompt: 'Eligible to work in North Macedonia?', kind: 'yes_no', required: true },
      ],
    })
    .select('id')
    .single()
  if (jobErr || !job) throw new Error(`Could not seed job: ${jobErr?.message}`)
  const { data: candidate, error: candErr } = await db
    .from('candidates')
    .insert({ full_name: CANDIDATE_NAME, email: CANDIDATE_EMAIL, phone: '+389 70 000 000' })
    .select('id')
    .single()
  if (candErr || !candidate) throw new Error(`Could not seed candidate: ${candErr?.message}`)
  const { data: app, error: appErr } = await db
    .from('applications')
    .insert({ job_id: job.id, company_id: company.id, candidate_id: candidate.id, source_channel_key: 'careers' })
    .select('id')
    .single()
  if (appErr || !app) throw new Error(`Could not seed application: ${appErr?.message}`)
  applicationId = app.id
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('candidate page: files behind signed links, screening answers, decision, notes, rejection', async ({
  page,
  request,
}, testInfo) => {
  const db = serviceClient()
  await page.route('**/api/hiring/notify-assignment', route => route.fulfill({ json: { emailSent: false, message: 'Email not sent in this test.' } }))

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // From the job's Applications tab, the row links to the candidate page.
  const { data: job } = await db.from('jobs').select('id').eq('title', JOB_TITLE).single()
  await page.goto(`/hiring/jobs/${job?.id}?tab=applications`)
  const row = page.locator('.application-row', { hasText: CANDIDATE_NAME })
  await row.getByRole('link', { name: CANDIDATE_NAME }).click()
  await expect(page).toHaveURL(new RegExp(`/hiring/applications/${applicationId}$`))
  await expect(page.getByRole('heading', { name: CANDIDATE_NAME })).toBeVisible()
  await expect(page.getByText(CANDIDATE_EMAIL)).toBeVisible()
  await expect(page.locator('.stage-badge')).toHaveText('new')

  // Files: upload a CV; it lists with size and a download that works only when signed.
  const files = page.locator('.card', { hasText: 'Files' })
  await files.locator('#file-kind').selectOption('cv')
  await files.locator('#file-input').setInputFiles({ name: 'cathy-cv.pdf', mimeType: 'application/pdf', buffer: PDF })
  await files.getByRole('button', { name: 'Upload' }).click()
  const fileRow = files.locator('.file-row', { hasText: 'cathy-cv.pdf' })
  await expect(fileRow).toBeVisible()
  await expect(fileRow).toContainText('CV / résumé')

  const { data: fileRows } = await db.from('application_files').select('storage_path, company_id').eq('application_id', applicationId)
  expect(fileRows?.length).toBe(1)
  const storagePath = fileRows?.[0]?.storage_path ?? ''
  const publicUrl = db.storage.from('candidate-files').getPublicUrl(storagePath).data.publicUrl
  const unsigned = await request.get(publicUrl)
  expect(unsigned.status()).toBeGreaterThanOrEqual(400) // private bucket: no public reads

  const [download] = await Promise.all([
    page.waitForEvent('popup').catch(() => null),
    fileRow.getByRole('button', { name: 'Download' }).click(),
  ])
  if (download) await download.close()
  const { data: signed } = await db.storage.from('candidate-files').createSignedUrl(storagePath, 60)
  const signedRes = await request.get(signed?.signedUrl ?? '')
  expect(signedRes.status()).toBe(200)

  // Screening answers against the job's questions.
  const answers = page.locator('.card', { hasText: 'Screening answers' })
  await expect(answers).toContainText('Why this role?')
  await answers.locator('.answer-row', { hasText: 'Why this role?' }).locator('textarea').fill('I have run a warehouse before.')
  await answers.locator('.answer-row', { hasText: 'Eligible to work' }).locator('select').selectOption('yes')
  await answers.getByRole('button', { name: 'Save answers' }).click()
  await expect(answers.getByText('Answers saved')).toBeVisible()
  const { data: appRow } = await db.from('applications').select('screening_answers').eq('id', applicationId).single()
  expect(appRow?.screening_answers).toEqual([
    { question_id: 'q-why', answer: 'I have run a warehouse before.' },
    { question_id: 'q-eligible', answer: 'yes' },
  ])

  // One guided action saves the stage, owner and deadline together.
  await page.getByRole('button', { name: 'Start screening', exact: true }).click()
  const handoff = page.getByRole('dialog', { name: 'Start screening' })
  await handoff.getByRole('button', { name: 'Start screening', exact: true }).click()
  await expect(handoff.getByRole('alert')).toBeVisible()
  await handoff.locator('#handoff-owner').selectOption({ label: 'Naum Simidjioski' })
  await handoff.locator('#handoff-action').fill('Phone screen')
  await handoff.locator('#handoff-due').fill('2026-10-01')
  await handoff.getByRole('button', { name: 'Start screening', exact: true }).click()
  await expect(page.locator('.stage-badge')).toHaveText('screening')
  await expect(page.getByRole('status')).toContainText('Email not sent in this test.')
  await page.goto('/overview')
  const assignedTask = page.locator('.queue-row', { hasText: CANDIDATE_NAME })
  await expect(assignedTask).toContainText('Phone screen')
  await assignedTask.getByRole('link', { name: 'Open candidate' }).click()
  await expect(page.locator('.stage-badge')).toHaveText('screening')

  await page.screenshot({ path: testInfo.outputPath('screening.png'), fullPage: true })
  await page.getByRole('button', { name: 'Edit assignment' }).click()
  await page.screenshot({ path: testInfo.outputPath('edit-assignment.png') })
  await expect(page.getByRole('dialog').locator('#handoff-action')).toHaveValue('Phone screen')
  await db.from('applications').update({ next_action: 'Colleague changed this assignment' }).eq('id', applicationId)
  await page.getByRole('dialog').getByRole('button', { name: 'Save assignment' }).click()
  await expect(page.getByRole('dialog').getByRole('alert')).toContainText('changed since you opened')
  await expect(page.getByRole('dialog').locator('#handoff-action')).toHaveValue('Phone screen')

  await page.getByRole('dialog').getByRole('button', { name: 'Cancel' }).click()
  await page.reload()
  await page.getByRole('button', { name: 'Record screening outcome' }).click()
  await page.getByRole('dialog').locator('#handoff-outcome').selectOption('screening')
  await page.getByRole('dialog').locator('#handoff-note').fill('Need to check availability before arranging interview.')
  await page.getByRole('dialog').getByRole('button', { name: 'Save outcome and next step' }).click()
  await expect(page.getByRole('dialog')).not.toBeVisible()
  await expect(page.locator('.stage-badge')).toHaveText('screening')

  const timeline = page.locator('.card', { hasText: 'Timeline' })
  await timeline.locator('#note-body').fill('Strong warehouse background; check references.')
  await timeline.getByRole('button', { name: 'Add note' }).click()
  await expect(timeline.locator('.event-row', { hasText: 'Strong warehouse background' })).toBeVisible()

  // Stage move from the panel, then a rejection with a required reason.
  await page.getByRole('button', { name: 'Record screening outcome' }).click()
  await page.getByRole('dialog').locator('#handoff-note').fill('Screening passed; arrange technical interview.')
  await page.getByRole('dialog').getByRole('button', { name: 'Save outcome and next step' }).click()
  await expect(page.locator('.stage-badge')).toHaveText('interview')
  await page.locator('.decision-panel').getByRole('button', { name: 'Reject', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByRole('button', { name: 'Reject application' }).click()
  await expect(dialog.getByText('Give the reason')).toBeVisible()
  await dialog.locator('#reject-reason').fill('Not enough scheduling experience for this role.')
  await dialog.getByRole('button', { name: 'Reject application' }).click()
  await expect(page.locator('.stage-badge')).toHaveText('rejected')
  await expect(timeline.locator('.event-row', { hasText: 'interview → rejected' })).toBeVisible()
  await expect(timeline.locator('.event-row', { hasText: 'Not enough scheduling experience' })).toBeVisible()

  const { data: rejected } = await db.from('applications').select('stage_key, rejected_reason, next_action').eq('id', applicationId).single()
  expect(rejected?.stage_key).toBe('rejected')
  expect(rejected?.rejected_reason).toBe('Not enough scheduling experience for this role.')
  expect(rejected?.next_action).toBe('Schedule interview')

  // Back on the job, the row shows the owner and the terminal stage.
  await page.getByRole('link', { name: '← Back to the job' }).click()
  await expect(page.locator('.application-row', { hasText: CANDIDATE_NAME })).toContainText('Naum Simidjioski')
})
