import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * The talent pool (plan 052): a pool holder adds a person to the pool by
 * hand, puts the CV on their record, adds them to a job from the record,
 * finds them again from the pool tab with their latest application, sets
 * the "never contact again" rule, and sees the job-side picker refuse to
 * offer them. Seeds two open Snowball jobs with the service client; cleans
 * rows and the candidate/<id>/ objects before and after.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const JOB_A = 'E2E Pool Role A'
const JOB_B = 'E2E Pool Role B'
const PERSON_NAME = 'E2E Pool Person'
const PERSON_EMAIL = 'e2e-pool@example.test'
const PERSON_LINKEDIN = 'https://www.linkedin.com/in/e2e-pool-person'
const NEVER_REASON = 'E2E: asked to stop'
const CV_NAME = 'e2e-pool-cv.pdf'
const BUCKET = 'candidate-files'

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

type Db = ReturnType<typeof serviceClient>

let jobAId = ''
let jobBId = ''

async function removeCandidateObjects(db: Db, candidateId: string): Promise<void> {
  const { data: objects } = await db.storage.from(BUCKET).list(`candidate/${candidateId}`)
  const paths = (objects ?? []).map((o) => `candidate/${candidateId}/${o.name}`)
  if (paths.length) await db.storage.from(BUCKET).remove(paths)
}

async function deleteApplications(db: Db, appIds: string[]): Promise<void> {
  if (!appIds.length) return
  await db.from('application_files').delete().in('application_id', appIds)
  await db.from('application_events').delete().in('application_id', appIds)
  await db.from('applications').delete().in('id', appIds)
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  // The person, by either identity, with their applications and objects.
  const { data: byName } = await db.from('candidates').select('id').eq('full_name', PERSON_NAME)
  const { data: byEmail } = await db.from('candidates').select('id').eq('email', PERSON_EMAIL)
  const candidateIds = [...new Set([...(byName ?? []), ...(byEmail ?? [])].map((c) => c.id))]
  if (candidateIds.length) {
    const { data: apps } = await db.from('applications').select('id').in('candidate_id', candidateIds)
    await deleteApplications(db, (apps ?? []).map((a) => a.id))
    for (const id of candidateIds) await removeCandidateObjects(db, id)
    // candidate_files rows go with the candidate (on delete cascade).
    await db.from('candidates').delete().in('id', candidateIds)
  }
  // The jobs, with whatever else landed on them.
  const { data: jobs } = await db.from('jobs').select('id').in('title', [JOB_A, JOB_B])
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
  const { data: jobs, error } = await db
    .from('jobs')
    .insert([
      { company_id: company.id, title: JOB_A, description: 'Pool role A', status: 'open' },
      { company_id: company.id, title: JOB_B, description: 'Pool role B', status: 'open' },
    ])
    .select('id, title')
  if (error || !jobs) throw new Error(`Could not seed jobs: ${error?.message}`)
  jobAId = jobs.find((j) => j.title === JOB_A)?.id ?? ''
  jobBId = jobs.find((j) => j.title === JOB_B)?.id ?? ''
  if (!jobAId || !jobBId) throw new Error('Seeded jobs missing')
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('add to pool → CV on the record → add to job → found in the pool → never contact → the picker refuses', async ({
  page,
}) => {
  const db = serviceClient()
  const { data: admin } = await db.from('people').select('id').ilike('work_email', ADMIN_EMAIL).single()
  expect(admin?.id).toBeTruthy()

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // The pool tab, for a pool holder (the admin), and "Add to pool".
  await page.goto('/hiring?tab=pool')
  await expect(page.getByTestId('hiring-tab-pool')).toBeVisible()
  await expect(page.getByTestId('talent-pool')).toBeVisible()
  await page.getByTestId('pool-add').click()
  const addDialog = page.getByRole('dialog', { name: 'Add to the talent pool.' })
  await expect(addDialog).toBeVisible()
  await addDialog.locator('#ac-name').fill(PERSON_NAME)
  await addDialog.locator('#ac-email').fill(PERSON_EMAIL)
  await addDialog.locator('#ac-linkedin').fill(PERSON_LINKEDIN)
  await expect(addDialog.locator('#ac-source')).toHaveValue('head_hunt')
  await addDialog.getByRole('button', { name: 'Add to pool' }).click()

  // The record opens.
  await expect(page).toHaveURL(/\/hiring\/candidates\/[0-9a-f-]{36}$/)
  const candidateId = page.url().match(/\/hiring\/candidates\/([0-9a-f-]{36})$/)?.[1] ?? ''
  expect(candidateId).toBeTruthy()
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  await expect(page.getByTestId('candidate-page')).toContainText('Talent pool · Head hunt')
  await expect(page.getByTestId('candidate-contact-line')).toHaveText('Can be contacted')

  // Files: the CV lands on the candidate, under candidate/<id>/.
  const files = page.getByTestId('candidate-files')
  await expect(files).toContainText('No files yet. The CV goes here — it follows the person to every job.')
  await files.locator('#candidate-file-kind').selectOption('cv')
  await files.locator('#candidate-file-input').setInputFiles({ name: CV_NAME, mimeType: 'application/pdf', buffer: PDF })
  await files.getByRole('button', { name: 'Upload' }).click()
  const fileRow = files.locator('.file-row', { hasText: CV_NAME })
  await expect(fileRow).toBeVisible()
  await expect(fileRow).toContainText('CV')
  const { data: fileRows } = await db.from('candidate_files').select('kind, storage_path').eq('candidate_id', candidateId)
  expect(fileRows).toHaveLength(1)
  expect(fileRows?.[0]?.kind).toBe('cv')
  expect(fileRows?.[0]?.storage_path.startsWith(`candidate/${candidateId}/`)).toBe(true)

  // Add to job → job A → the application page.
  await page.getByTestId('candidate-add-to-job').click()
  const sourceDialog = page.getByTestId('source-to-job')
  await expect(sourceDialog).toBeVisible()
  await expect(sourceDialog).toContainText(`Add ${PERSON_NAME} to a job.`)
  await sourceDialog.getByTestId('source-job-select').selectOption(jobAId)
  await sourceDialog.getByTestId('source-job-submit').click()
  await expect(page).toHaveURL(/\/hiring\/applications\/[0-9a-f-]{36}$/)
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  await expect(page.locator('.stage-badge')).toHaveText('new')
  const { data: apps } = await db
    .from('applications')
    .select('id, job_id, source_key, stage_key')
    .eq('candidate_id', candidateId)
  expect(apps).toHaveLength(1)
  expect(apps?.[0]?.job_id).toBe(jobAId)
  expect(apps?.[0]?.source_key).toBe('head_hunt')
  expect(apps?.[0]?.stage_key).toBe('new')

  // Back to the pool: the search finds the row with its latest application.
  // A partial name is enough (0068): every word of the query's key is a
  // word-prefix of some word of the candidate's key ("e e pool" against
  // "e e person pool"), order-free. The search is asserted through the
  // address bar, so the row is the search's, not the unfiltered load's.
  await page.goto('/hiring?tab=pool')
  await page.getByTestId('pool-search').fill('E2E Pool')
  await expect(page).toHaveURL(/tab=pool/)
  await expect(page).toHaveURL(/q=E2E(\+|%20)Pool(&|$)/)
  await expect(page.getByTestId('pool-count')).toContainText('1 person · showing 1')
  const poolRow = page.getByTestId(`pool-row-${candidateId}`)
  await expect(poolRow).toBeVisible()
  await expect(poolRow).toContainText(PERSON_EMAIL)
  await expect(poolRow).toContainText('Head hunt')
  // "<count> · latest: <title>, <company> — <stage>": the parts, not the company name.
  await expect(poolRow).toContainText(`1 · latest: ${JOB_A}`)
  await expect(poolRow).toContainText(new RegExp(`1 · latest: ${JOB_A}, .+ — new`))

  // Contact rule → Never, with the reason everyone will read.
  await poolRow.getByRole('link', { name: 'Open' }).click()
  await expect(page).toHaveURL(new RegExp(`/hiring/candidates/${candidateId}$`))
  await page.getByTestId('candidate-contact-rule').click()
  const ruleDialog = page.getByTestId('contact-rule')
  await expect(ruleDialog).toBeVisible()
  await expect(ruleDialog).toContainText(`How may we contact ${PERSON_NAME}?`)
  await ruleDialog.getByTestId('contact-rule-never').check()
  await ruleDialog.getByTestId('contact-rule-reason').fill(NEVER_REASON)
  await ruleDialog.getByTestId('contact-rule-save').click()
  await expect(ruleDialog).toBeHidden()
  await expect(page.getByTestId('candidate-contact-badge')).toHaveText('Do not contact')
  await expect(page.getByTestId('candidate-never-line')).toContainText(`Asked not to be contacted again — ${NEVER_REASON}`)
  await expect(page.getByTestId('candidate-contact-line')).toHaveText(`Asked not to be contacted: ${NEVER_REASON}`)
  await expect(page.getByTestId('candidate-add-to-job')).toBeDisabled()
  const { data: flagged } = await db
    .from('candidates')
    .select('do_not_contact, do_not_contact_reason, do_not_contact_by, contact_later')
    .eq('id', candidateId)
    .single()
  expect(flagged?.do_not_contact).toBe(true)
  expect(flagged?.do_not_contact_reason).toBe(NEVER_REASON)
  expect(flagged?.do_not_contact_by).toBe(admin?.id)
  expect(flagged?.contact_later).toBe(false)

  // Job B → Source from pool: the row is shown flagged, with no way to add it.
  await page.goto(`/hiring/jobs/${jobBId}?tab=applications`)
  await page.getByTestId('source-from-pool').click()
  const pick = page.getByTestId('pick-from-pool')
  await expect(pick).toBeVisible()
  await expect(pick).toContainText('Type a name, email, LinkedIn address, title or skill.')
  await pick.getByTestId('pool-search').fill(PERSON_NAME)
  const pickRow = pick.getByTestId(`pool-pick-row-${candidateId}`)
  await expect(pickRow).toBeVisible()
  await expect(pickRow).toContainText(PERSON_NAME)
  await expect(pickRow).toContainText('Do not contact')
  await expect(pick.getByTestId(`pool-pick-${candidateId}`)).toHaveCount(0)
})
