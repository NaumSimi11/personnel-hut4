import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Bulk CVs: HR drops the files they have on a laptop into a job, each
 * becomes a candidate at "New" with the CV attached; a name is guessed from
 * the file name and can be corrected before saving. Seeds an open job at
 * Snowball.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const JOB_TITLE = 'E2E Bulk CV Role'

const PDF = Buffer.from(
  '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000052 00000 n \n0000000101 00000 n \ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n160\n%%EOF\n',
)

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let jobId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: jobs } = await db.from('jobs').select('id').eq('title', JOB_TITLE)
  const jobIds = (jobs ?? []).map((j) => j.id)
  if (!jobIds.length) return
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

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'SNOW').single()
  if (!company) throw new Error('Snowball not found')
  const { data: job, error } = await db
    .from('jobs')
    .insert({ company_id: company.id, title: JOB_TITLE, description: 'Bulk CV role', status: 'open' })
    .select('id')
    .single()
  if (error || !job) throw new Error(`Could not seed job: ${error?.message}`)
  jobId = job.id
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('drop three CVs → names guessed and corrected → three candidates with the CV attached', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto(`/hiring/jobs/${jobId}?tab=applications`)
  await page.getByRole('button', { name: 'Upload CVs' }).click()
  const dialog = page.getByRole('dialog')
  await dialog.locator('input[type=file]').setInputFiles([
    { name: 'Ana_Ilievska_CV.pdf', mimeType: 'application/pdf', buffer: PDF },
    { name: 'cv-marko-petrov-2026.pdf', mimeType: 'application/pdf', buffer: PDF },
    { name: 'CV.pdf', mimeType: 'application/pdf', buffer: PDF },
  ])

  // Guessed names, one corrected by hand.
  await expect(dialog.getByTestId('cv-row-0').locator('.name')).toHaveValue('Ana Ilievska')
  await expect(dialog.getByTestId('cv-row-1').locator('.name')).toHaveValue('Marko Petrov')
  await dialog.getByTestId('cv-row-2').locator('.name').fill('Elena Trajkovska')
  await dialog.getByTestId('cv-row-2').locator('.email').fill('elena@example.test')
  await dialog.getByRole('button', { name: /Save 3 candidates/ }).click()
  await expect(dialog).toBeHidden()

  // All three on the Applications tab, each with the CV in the database.
  for (const name of ['Ana Ilievska', 'Marko Petrov', 'Elena Trajkovska']) {
    await expect(page.getByText(name, { exact: true }).first()).toBeVisible()
  }
  const { data: apps } = await db
    .from('applications')
    .select('stage_key, candidate:candidates(full_name, email), application_files(kind, original_name)')
    .eq('job_id', jobId)
  expect(apps).toHaveLength(3)
  for (const a of apps ?? []) {
    expect(a.stage_key).toBe('new')
    expect(a.application_files).toHaveLength(1)
    expect(a.application_files[0]?.kind).toBe('cv')
  }
  const elena = (apps ?? []).find((a) => (a.candidate as unknown as { full_name: string }).full_name === 'Elena Trajkovska')
  expect((elena?.candidate as unknown as { email: string }).email).toBe('elena@example.test')
  expect(elena?.application_files[0]?.original_name).toBe('CV.pdf')
})
