import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Deduplication at the door (plan 052, blueprint §5): a candidate already in
 * the pool is offered as a match before anything is written — never merged
 * by itself. From "Add candidate" the person attaches the existing record to
 * the job (one candidates row); from "Upload CVs" the person creates a new
 * record anyway (two rows, the CV on the new one, listed on the application
 * under "Candidate's files"). Seeds a pool candidate (provider e2e) with a
 * rejected application on job A and an open job B; cleans rows and the
 * candidate/<id>/ objects before and after.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const JOB_A = 'E2E Dedupe Role A'
const JOB_B = 'E2E Dedupe Role B'
const PERSON_NAME = 'E2E Pool Person'
const PERSON_EMAIL = 'e2e-dedupe@example.test'
const PROVIDER = 'e2e'
const PROVIDER_REF = 'pool-1'
const CV_FILE = 'E2E_Pool_Person_CV.pdf'
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
let poolCandidateId = ''

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
  const { data: byName } = await db.from('candidates').select('id').eq('full_name', PERSON_NAME)
  const { data: byEmail } = await db.from('candidates').select('id').eq('email', PERSON_EMAIL)
  const { data: byRef } = await db.from('candidates').select('id').eq('provider', PROVIDER).eq('provider_ref', PROVIDER_REF)
  const candidateIds = [...new Set([...(byName ?? []), ...(byEmail ?? []), ...(byRef ?? [])].map((c) => c.id))]
  if (candidateIds.length) {
    const { data: apps } = await db.from('applications').select('id').in('candidate_id', candidateIds)
    await deleteApplications(db, (apps ?? []).map((a) => a.id))
    for (const id of candidateIds) await removeCandidateObjects(db, id)
    // candidate_files rows go with the candidate (on delete cascade).
    await db.from('candidates').delete().in('id', candidateIds)
  }
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
  const { data: jobs, error: jobErr } = await db
    .from('jobs')
    .insert([
      { company_id: company.id, title: JOB_A, description: 'Dedupe role A', status: 'open' },
      { company_id: company.id, title: JOB_B, description: 'Dedupe role B', status: 'open' },
    ])
    .select('id, title')
  if (jobErr || !jobs) throw new Error(`Could not seed jobs: ${jobErr?.message}`)
  jobAId = jobs.find((j) => j.title === JOB_A)?.id ?? ''
  jobBId = jobs.find((j) => j.title === JOB_B)?.id ?? ''
  if (!jobAId || !jobBId) throw new Error('Seeded jobs missing')

  // A provider-keyed pool record (the service client passes the guards: no
  // auth.uid()); the generated keys fill themselves.
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
  poolCandidateId = candidate.id

  const { error: appErr } = await db.from('applications').insert({
    job_id: jobAId,
    company_id: company.id,
    candidate_id: poolCandidateId,
    stage_key: 'rejected',
    source_key: 'head_hunt',
    rejected_reason: 'E2E: not this time',
  })
  if (appErr) throw new Error(`Could not seed application: ${appErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('add candidate offers the match → attach; upload CVs offers it → create new with the CV on the record', async ({
  page,
}) => {
  const db = serviceClient()

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // Job B → Add candidate with the pool record's email: the match, not a write.
  await page.goto(`/hiring/jobs/${jobBId}?tab=applications`)
  await page.getByRole('button', { name: 'Add candidate' }).click()
  const addDialog = page.getByRole('dialog', { name: 'Add a candidate.' })
  await expect(addDialog).toBeVisible()
  await addDialog.locator('#ac-name').fill(PERSON_NAME)
  await addDialog.locator('#ac-email').fill(PERSON_EMAIL)
  await addDialog.getByRole('button', { name: 'Save candidate' }).click()
  const matches = page.getByTestId('candidate-matches')
  await expect(matches).toBeVisible()
  await expect(matches).toContainText('Is this the same person?')
  const match = matches.getByTestId(`match-${poolCandidateId}`)
  await expect(match).toContainText(`This looks like ${PERSON_NAME} (same email).`)
  await expect(match).toContainText(new RegExp(`Applied to ${JOB_A} at .+ — rejected, [A-Z][a-z]{2} \\d{4}\\.`))
  const { count: beforeAttach } = await db.from('candidates').select('id', { count: 'exact', head: true }).eq('email', PERSON_EMAIL)
  expect(beforeAttach).toBe(1)

  // Attach to this job: a B application on the same candidates row.
  await match.getByTestId(`match-attach-${poolCandidateId}`).click()
  await expect(matches).toBeHidden()
  const attachedRow = page.locator('.application-row', { hasText: PERSON_NAME })
  await expect(attachedRow).toBeVisible()
  await expect(attachedRow).toContainText('new')
  const { data: bApps } = await db
    .from('applications')
    .select('id, candidate_id, stage_key')
    .eq('job_id', jobBId)
  expect(bApps).toHaveLength(1)
  expect(bApps?.[0]?.candidate_id).toBe(poolCandidateId)
  expect(bApps?.[0]?.stage_key).toBe('new')
  const { count: afterAttach } = await db.from('candidates').select('id', { count: 'exact', head: true }).eq('email', PERSON_EMAIL)
  expect(afterAttach).toBe(1)

  // Upload CVs with the same person: the row shows the choice; create a new
  // candidate anyway.
  await page.getByRole('button', { name: 'Upload CVs' }).click()
  const uploadDialog = page.getByRole('dialog', { name: /Upload CVs/ })
  await expect(uploadDialog).toBeVisible()
  await uploadDialog.locator('input[type=file]').setInputFiles([{ name: CV_FILE, mimeType: 'application/pdf', buffer: PDF }])
  const cvRow = uploadDialog.getByTestId('cv-row-0')
  await cvRow.locator('.name').fill(PERSON_NAME)
  await cvRow.locator('.email').fill(PERSON_EMAIL)
  await uploadDialog.getByRole('button', { name: /Save 1 candidate/ }).click()
  await expect(cvRow).toContainText('Is this the same person?')
  const cvMatches = uploadDialog.getByTestId('cv-matches-0')
  await expect(cvMatches).toContainText(`This looks like ${PERSON_NAME} (same email).`)
  await expect(cvMatches.getByTestId(`cv-attach-0-${poolCandidateId}`)).toBeVisible()
  await cvMatches.getByTestId('cv-create-new-0').click()
  await expect(uploadDialog).toBeHidden()

  // A second candidates row with email X, the CV in candidate_files.
  const { data: candidates } = await db
    .from('candidates')
    .select('id, provider, candidate_files(kind, original_name, storage_path)')
    .eq('email', PERSON_EMAIL)
  expect(candidates).toHaveLength(2)
  const created = (candidates ?? []).find((c) => c.id !== poolCandidateId)
  expect(created?.provider).toBe('manual')
  expect(created?.candidate_files).toHaveLength(1)
  expect(created?.candidate_files[0]?.kind).toBe('cv')
  expect(created?.candidate_files[0]?.original_name).toBe(CV_FILE)
  expect(created?.candidate_files[0]?.storage_path.startsWith(`candidate/${created?.id}/`)).toBe(true)
  const { data: createdApps } = await db
    .from('applications')
    .select('id, stage_key')
    .eq('job_id', jobBId)
    .eq('candidate_id', created?.id ?? '')
  expect(createdApps).toHaveLength(1)
  expect(createdApps?.[0]?.stage_key).toBe('new')

  // The application page lists the CV under "Candidate's files".
  await page.goto(`/hiring/applications/${createdApps?.[0]?.id}`)
  await expect(page.getByRole('heading', { name: PERSON_NAME })).toBeVisible()
  const candidateFiles = page.locator('.card', { hasText: "Candidate's files — shared across their applications" })
  await expect(candidateFiles).toBeVisible()
  await expect(candidateFiles.locator('.file-row', { hasText: CV_FILE })).toBeVisible()
  await expect(page.locator('.card', { hasText: 'Files for this application' })).toContainText('No files attached yet.')
})
