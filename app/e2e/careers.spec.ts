import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Careers page & intake (plan 019): an anonymous visitor sees a company's
 * open roles, reads one brief, applies with a CV and screening answers, gets
 * a reference; applying again is refused; a honeypot submission is dropped
 * silently; and the recruiter then finds the application with its file,
 * answers and source. Seeds a job with a live careers listing.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const JOB_TITLE = 'E2E Careers Role'
const APPLICANT_NAME = 'E2E Careers Applicant'
// Unique per run: the intake rate limit is per email and lives in the server's memory.
const RUN_ID = Date.now().toString(36).slice(-6)
const APPLICANT_EMAIL = `e2e-careers-${RUN_ID}@example.test`
const BOT_EMAIL = `e2e-careers-bot-${RUN_ID}@example.test`

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
  const { data: candidates } = await db.from('candidates').select('id').like('email', 'e2e-careers-%@example.test')
  const candidateIds = (candidates ?? []).map((c) => c.id)
  if (candidateIds.length) {
    const { data: apps } = await db.from('applications').select('id').in('candidate_id', candidateIds)
    for (const a of apps ?? []) {
      const { data: objects } = await db.storage.from('candidate-files').list(a.id)
      const paths = (objects ?? []).map((o) => `${a.id}/${o.name}`)
      if (paths.length) await db.storage.from('candidate-files').remove(paths)
    }
    const appIds = (apps ?? []).map((a) => a.id)
    if (appIds.length) {
      await db.from('application_files').delete().in('application_id', appIds)
      await db.from('application_events').delete().in('application_id', appIds)
      await db.from('applications').delete().in('id', appIds)
    }
    await db.from('candidates').delete().in('id', candidateIds)
  }
  await db.from('jobs').delete().eq('title', JOB_TITLE) // job_channels cascade
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'SNOW').single()
  if (!company) throw new Error('Snowball not found')
  const { data: job, error } = await db
    .from('jobs')
    .insert({
      company_id: company.id,
      title: JOB_TITLE,
      description: 'Run the Snowball warehouse schedule and supplier handovers. Skopje, full-time.',
      status: 'open',
      description_revision: 2,
      screening_questions: [
        { id: 'q-why', prompt: 'Why this role?', kind: 'text', required: true },
        { id: 'q-eligible', prompt: 'Eligible to work in North Macedonia?', kind: 'yes_no', required: true },
        { id: 'q-notice', prompt: 'Notice period', kind: 'choice', required: false, options: ['Immediate', '1 month', '2 months'] },
      ],
    })
    .select('id')
    .single()
  if (error || !job) throw new Error(`Could not seed job: ${error?.message}`)
  jobId = job.id
  const { error: chErr } = await db
    .from('job_channels')
    .insert({ job_id: job.id, channel_key: 'careers', status: 'live', published_revision: 2 })
  if (chErr) throw new Error(`Could not seed listing: ${chErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('anonymous applicant → reference → duplicate refused → honeypot dropped → recruiter sees it all', async ({
  browser,
  page,
}) => {
  const db = serviceClient()

  // A visitor with no session at all.
  const visitor = await browser.newContext()
  const pub = await visitor.newPage()
  await pub.goto('/careers/snow')
  await expect(pub.getByRole('heading', { name: /Snowball/ })).toBeVisible()
  await expect(pub.locator('nav')).toHaveCount(0) // no app shell
  await pub.getByRole('link', { name: JOB_TITLE }).click()
  await expect(pub).toHaveURL(new RegExp(`/careers/snow/${jobId}$`))
  await expect(pub.getByRole('heading', { name: JOB_TITLE })).toBeVisible()
  await expect(pub.getByText('Run the Snowball warehouse schedule')).toBeVisible()

  await pub.locator('#apply-name').fill(APPLICANT_NAME)
  await pub.locator('#apply-email').fill(APPLICANT_EMAIL)
  await pub.locator('#apply-phone').fill('+389 70 123 456')
  await pub.locator('#apply-q-why').fill('I have run a warehouse for three seasons.')
  await pub.locator('#apply-q-eligible').selectOption('yes')
  await pub.locator('#apply-q-notice').selectOption('1 month')
  await pub.locator('#apply-cv').setInputFiles({ name: 'jamie-cv.pdf', mimeType: 'application/pdf', buffer: PDF })
  await pub.locator('#apply-consent').check()
  await pub.getByRole('button', { name: 'Send application' }).click()

  await expect(pub.getByRole('heading', { name: /Thank you/ })).toBeVisible()
  const reference = (await pub.locator('.reference').textContent())?.trim() ?? ''
  expect(reference).toMatch(/^[0-9A-F]{8}$/)

  // Applying again for the same role is refused, with a clear message.
  await pub.goto(`/careers/snow/${jobId}`)
  await pub.locator('#apply-name').fill(APPLICANT_NAME)
  await pub.locator('#apply-email').fill(APPLICANT_EMAIL)
  await pub.locator('#apply-q-why').fill('Again.')
  await pub.locator('#apply-q-eligible').selectOption('yes')
  await pub.locator('#apply-cv').setInputFiles({ name: 'jamie-cv.pdf', mimeType: 'application/pdf', buffer: PDF })
  await pub.locator('#apply-consent').check()
  await pub.getByRole('button', { name: 'Send application' }).click()
  await expect(pub.getByRole('alert')).toContainText('already applied')

  // A bot fills the hidden field: looks accepted, nothing stored.
  await pub.goto(`/careers/snow/${jobId}`)
  await pub.locator('#apply-name').fill('Bot Bot')
  await pub.locator('#apply-email').fill(BOT_EMAIL)
  await pub.locator('#apply-q-why').fill('spam')
  await pub.locator('#apply-q-eligible').selectOption('yes')
  await pub.locator('#apply-cv').setInputFiles({ name: 'spam.pdf', mimeType: 'application/pdf', buffer: PDF })
  await pub.locator('#apply-consent').check()
  await pub.evaluate(() => {
    const trap = document.querySelector<HTMLInputElement>('input[name="website"]')
    if (trap) trap.value = 'http://spam.example'
  })
  await pub.getByRole('button', { name: 'Send application' }).click()
  await expect(pub.getByRole('heading', { name: /Thank you/ })).toBeVisible()
  const { data: bots } = await db.from('candidates').select('id').eq('email', BOT_EMAIL)
  expect(bots?.length ?? 0).toBe(0)
  await visitor.close()

  // The recruiter finds the real application: source, answers, CV.
  const { data: candidate } = await db.from('candidates').select('id, phone').eq('email', APPLICANT_EMAIL).single()
  expect(candidate?.phone).toBe('+389 70 123 456')
  const { data: application } = await db
    .from('applications')
    .select('id, source_channel_key, screening_answers, application_files(original_name, kind)')
    .eq('candidate_id', candidate!.id)
    .single()
  expect(application?.source_channel_key).toBe('careers')
  expect(application?.screening_answers).toEqual([
    { question_id: 'q-why', answer: 'I have run a warehouse for three seasons.' },
    { question_id: 'q-eligible', answer: 'yes' },
    { question_id: 'q-notice', answer: '1 month' },
  ])
  expect(application?.application_files?.[0]).toMatchObject({ original_name: 'jamie-cv.pdf', kind: 'cv' })
  expect(reference).toBe(application!.id.replace(/-/g, '').slice(0, 8).toUpperCase())

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)
  await page.goto(`/hiring/applications/${application!.id}`)
  await expect(page.getByRole('heading', { name: APPLICANT_NAME })).toBeVisible()
  await expect(page.getByText('via Company careers page')).toBeVisible()
  await expect(page.locator('.file-row', { hasText: 'jamie-cv.pdf' })).toBeVisible()
  await expect(page.locator('.answer-row', { hasText: 'Why this role?' }).locator('textarea')).toHaveValue(
    'I have run a warehouse for three seasons.',
  )
})
