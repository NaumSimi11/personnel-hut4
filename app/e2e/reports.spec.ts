import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Recruitment reporting (plan 021): KPIs, a per-job funnel, source
 * attribution and attention counts, all counted in the database by
 * recruitment_report. Seeds one open job at Snowball with applications at
 * several stages — one hired from the careers page — then reads the page
 * and exports the funnel as CSV.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const JOB_TITLE = 'E2E Report Role'
const EMAIL_PREFIX = 'e2e-report-'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: candidates } = await db.from('candidates').select('id').like('email', `${EMAIL_PREFIX}%`)
  const ids = (candidates ?? []).map((c) => c.id)
  if (ids.length) {
    const { data: apps } = await db.from('applications').select('id').in('candidate_id', ids)
    const appIds = (apps ?? []).map((a) => a.id)
    if (appIds.length) {
      await db.from('application_events').delete().in('application_id', appIds)
      await db.from('applications').delete().in('id', appIds)
    }
    await db.from('candidates').delete().in('id', ids)
  }
  await db.from('jobs').delete().eq('title', JOB_TITLE)
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'SNOW').single()
  if (!company) throw new Error('Snowball not found')
  const { data: job } = await db
    .from('jobs')
    .insert({ company_id: company.id, title: JOB_TITLE, status: 'open' })
    .select('id')
    .single()
  const stages: { stage: string; source: string | null; days: number; hiredDays?: number }[] = [
    { stage: 'new', source: 'careers', days: 3 },
    { stage: 'screening', source: 'careers', days: 6 },
    { stage: 'interview', source: null, days: 9 },
    { stage: 'rejected', source: 'careers', days: 12 },
    { stage: 'hired', source: 'careers', days: 30, hiredDays: 10 },
  ]
  for (const [i, s] of stages.entries()) {
    const { data: candidate } = await db
      .from('candidates')
      .insert({ full_name: `E2E Report Candidate ${i + 1}`, email: `${EMAIL_PREFIX}${i + 1}@example.test` })
      .select('id')
      .single()
    const received = new Date(Date.now() - s.days * 86400000).toISOString()
    const { data: app } = await db
      .from('applications')
      .insert({
        job_id: job!.id,
        company_id: company.id,
        candidate_id: candidate!.id,
        stage_key: s.stage,
        source_channel_key: s.source,
        received_at: received,
      })
      .select('id')
      .single()
    if (s.hiredDays !== undefined) {
      await db.from('application_events').insert({
        application_id: app!.id,
        kind: 'stage_change',
        from_stage_key: 'offer',
        to_stage_key: 'hired',
        created_at: new Date(Date.now() - s.hiredDays * 86400000).toISOString(),
      })
    }
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('reports page: KPIs, funnel, sources, attention, CSV export', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.getByRole('link', { name: 'Reports', exact: true }).click()
  await expect(page).toHaveURL(/\/reports/)

  await page.locator('#report-company').selectOption({ label: 'Snowball' })
  await expect(page.locator('.report-ready')).toBeVisible()

  // Funnel row for the seeded job: 5 received, stage counts, 1 hired.
  const row = page.locator('.funnel-row', { hasText: JOB_TITLE })
  await expect(row).toBeVisible()
  await expect(row.locator('[data-col="received"]')).toHaveText('5')
  await expect(row.locator('[data-col="new"]')).toHaveText('1')
  await expect(row.locator('[data-col="interview"]')).toHaveText('1')
  await expect(row.locator('[data-col="hired"]')).toHaveText('1')

  // Sources: careers 4 received / 1 hired; added by hand 1.
  const careers = page.locator('.source-row', { hasText: 'Company careers page' })
  await expect(careers.locator('[data-col="received"]')).toHaveText('4')
  await expect(careers.locator('[data-col="hired"]')).toHaveText('1')
  await expect(page.locator('.source-row', { hasText: 'Added by hand' }).locator('[data-col="received"]')).toHaveText('1')

  // KPIs: hires and time-to-hire come from the hired event (20 days).
  const kpis = page.locator('.kpi')
  await expect(kpis.filter({ hasText: 'Hires' }).locator('.kpi-value')).toHaveText('1')
  await expect(kpis.filter({ hasText: 'Median days to hire' }).locator('.kpi-value')).toHaveText(/^20(\.0)?$/)

  // Attention: unassigned counts the three non-terminal applications without an owner.
  await expect(page.locator('.attention', { hasText: 'Unassigned' }).locator('.kpi-value')).toHaveText('3')

  // CSV export of the funnel.
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.getByRole('button', { name: 'Export funnel (CSV)' }).click(),
  ])
  expect(download.suggestedFilename()).toMatch(/recruitment-funnel-.*\.csv$/)
  const text = await (await download.createReadStream()).toArray().then((chunks) => Buffer.concat(chunks).toString())
  expect(text.split('\n')[0]).toBe('Job,Status,Received,New,Screening,Interview,Offer,Hired,Rejected,Withdrawn')
  expect(text).toContain(`${JOB_TITLE},open,5,1,1,1,0,1,1,0`)
})
