import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Closing job openings from the Hiring list (plan 056). An admin picks a
 * seeded opening with three candidates still in play, closes it with the
 * withdraw switch on, and sees the row fall to zero in play with the closing
 * line under its status; the candidates are withdrawn in the database with
 * the reason. A second opening nobody ever applied to is deleted from the
 * same list, while the first one's Delete stays disabled and says why.
 *
 * Seeds one Snowball job with three applications and one empty job; cleans
 * before and after, so a failed run leaves nothing behind either.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const BUSY_JOB = 'E2E Close Busy Role'
const EMPTY_JOB = 'E2E Close Empty Role'
const NAME_PREFIX = 'E2E Close '
const NAMES = ['Ana', 'Ben', 'Cal'] as const
const REASON = 'E2E: headcount withdrawn for the year.'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

type Db = ReturnType<typeof serviceClient>

let busyJobId = ''
let emptyJobId = ''

async function deleteApplications(db: Db, ids: string[]): Promise<void> {
  if (!ids.length) return
  await db.from('application_files').delete().in('application_id', ids)
  await db.from('application_events').delete().in('application_id', ids)
  await db.from('applications').delete().in('id', ids)
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: candidates } = await db.from('candidates').select('id').like('full_name', `${NAME_PREFIX}%`)
  const candidateIds = (candidates ?? []).map((c) => c.id)
  if (candidateIds.length) {
    const { data: apps } = await db.from('applications').select('id').in('candidate_id', candidateIds)
    await deleteApplications(
      db,
      (apps ?? []).map((a) => a.id),
    )
    await db.from('candidates').delete().in('id', candidateIds)
  }
  const { data: jobs } = await db.from('jobs').select('id').in('title', [BUSY_JOB, EMPTY_JOB])
  const jobIds = (jobs ?? []).map((j) => j.id)
  if (jobIds.length) {
    const { data: apps } = await db.from('applications').select('id').in('job_id', jobIds)
    await deleteApplications(
      db,
      (apps ?? []).map((a) => a.id),
    )
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
      { company_id: company.id, title: BUSY_JOB, description: 'Busy role', status: 'open' },
      { company_id: company.id, title: EMPTY_JOB, description: 'Empty role', status: 'open' },
    ])
    .select('id, title')
  if (jobErr || !jobs) throw new Error(`Could not seed the jobs: ${jobErr?.message}`)
  busyJobId = jobs.find((j) => j.title === BUSY_JOB)?.id ?? ''
  emptyJobId = jobs.find((j) => j.title === EMPTY_JOB)?.id ?? ''

  for (const name of NAMES) {
    const { data: candidate, error: candErr } = await db
      .from('candidates')
      .insert({ full_name: `${NAME_PREFIX}${name}` })
      .select('id')
      .single()
    if (candErr || !candidate) throw new Error(`Could not seed candidate ${name}: ${candErr?.message}`)
    const { error: appErr } = await db.from('applications').insert({
      job_id: busyJobId,
      company_id: company.id,
      candidate_id: candidate.id,
      stage_key: name === 'Cal' ? 'interview' : 'new',
      source_key: 'head_hunt',
    })
    if (appErr) throw new Error(`Could not seed application ${name}: ${appErr.message}`)
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

test('an admin abandons an opening and deletes an empty one', async ({ page }) => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto('/hiring?tab=openings')
  const busy = page.getByTestId(`opening-${busyJobId}`)
  await expect(busy).toBeVisible()
  await expect(busy.locator('.num').nth(1)).toHaveText('3')

  // A job somebody applied to cannot be deleted, and the button says so.
  const deleteBusy = page.getByTestId(`delete-${busyJobId}`)
  await expect(deleteBusy).toBeDisabled()
  await expect(deleteBusy).toHaveAttribute('title', /3 applications came in/)

  // Pick it and close it, withdrawing the three still in play.
  await page.getByTestId(`pick-${busyJobId}`).check()
  await page.getByTestId('close-selected').click()
  const dialog = page.getByTestId('close-jobs-dialog')
  await expect(dialog).toBeVisible()
  await expect(page.getByTestId('close-jobs-withdraw')).toBeChecked()
  await expect(page.getByTestId('close-jobs-question')).toContainText('3 candidates still in play will be withdrawn')
  await page.getByTestId('close-jobs-reason').fill(REASON)
  await page.getByTestId('close-jobs-confirm').click()

  await expect(page.getByTestId('openings-notice')).toContainText('1 opening closed · 3 candidates withdrawn.')

  // The list reloads on the live filter, which no longer holds a closed job.
  await page.locator('select[aria-label="Status"]').selectOption('closed')
  const closed = page.getByTestId(`opening-${busyJobId}`)
  await expect(closed).toContainText('Closed')
  await expect(page.getByTestId(`closed-${busyJobId}`)).toContainText(REASON)
  await expect(closed.locator('.num').nth(1)).toHaveText('0')

  // It really happened, not just on screen.
  const db = serviceClient()
  const { data: apps } = await db.from('applications').select('stage_key, withdrawn_reason').eq('job_id', busyJobId)
  expect(apps).toHaveLength(3)
  expect(apps?.every((a) => a.stage_key === 'withdrawn' && a.withdrawn_reason === REASON)).toBe(true)
  const { data: events } = await db
    .from('application_events')
    .select('to_stage_key')
    .eq('kind', 'stage_change')
    .eq('body', REASON)
  expect(events?.length).toBe(3)

  // The empty opening goes entirely.
  await page.locator('select[aria-label="Status"]').selectOption('all')
  await page.getByTestId(`delete-${emptyJobId}`).click()
  await confirmDialog(page)
  await expect(page.getByTestId('openings-notice')).toContainText(`${EMPTY_JOB} deleted.`)
  await expect(page.getByTestId(`opening-${emptyJobId}`)).toHaveCount(0)

  const { data: gone } = await db.from('jobs').select('id').eq('id', emptyJobId)
  expect(gone).toHaveLength(0)
})
