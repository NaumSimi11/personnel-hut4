import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Outreach sub-statuses (plan 054): the job's Applications tab shows the
 * sub-status beside the stage and flags "not responding"; two rows are
 * logged at once from the tab, one more from its application page; the
 * timeline carries the entry; the Reports attention tile counts it until
 * the fresh event clears it; a plain stage move to screening takes the
 * stage's default. Seeds one open Snowball job, three applications at new
 * (head hunt → sourced by the trigger) and one at screening whose only
 * activity is 31 days old; cleans before and after.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const JOB_TITLE = 'E2E Outreach Role'
const NAME_PREFIX = 'E2E Outreach '
const EMAIL_PREFIX = 'e2e-outreach-'
const NAMES = ['Ana', 'Ben', 'Cal', 'Dee'] as const
const VOICEMAIL_NOTE = 'E2E: left a voicemail'
const INTERESTED_NOTE = 'E2E: keen, wants to talk next week'
const QUIET_DAYS = 31
const DAY_MS = 86_400_000

const LABEL = {
  sourced: 'Sourced — not yet contacted',
  contactAttempted: 'Contact attempted — no answer yet',
  contacted: 'In conversation',
  interested: 'Interested',
} as const

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

type Db = ReturnType<typeof serviceClient>

let jobId = ''
/** Application id per seeded name. */
let appIds: Record<(typeof NAMES)[number], string> = { Ana: '', Ben: '', Cal: '', Dee: '' }

function candidateName(name: (typeof NAMES)[number]): string {
  return `${NAME_PREFIX}${name}`
}

async function deleteApplications(db: Db, ids: string[]): Promise<void> {
  if (!ids.length) return
  await db.from('application_files').delete().in('application_id', ids)
  await db.from('application_events').delete().in('application_id', ids)
  await db.from('applications').delete().in('id', ids)
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  await db.from('notifications').delete().like('title', `%${NAME_PREFIX}%`)
  const { data: byName } = await db.from('candidates').select('id').like('full_name', `${NAME_PREFIX}%`)
  const { data: byEmail } = await db.from('candidates').select('id').like('email', `${EMAIL_PREFIX}%`)
  const candidateIds = [...new Set([...(byName ?? []), ...(byEmail ?? [])].map((c) => c.id))]
  if (candidateIds.length) {
    const { data: apps } = await db.from('applications').select('id').in('candidate_id', candidateIds)
    await deleteApplications(db, (apps ?? []).map((a) => a.id))
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
    .insert({ company_id: company.id, title: JOB_TITLE, description: 'Outreach role', status: 'open' })
    .select('id')
    .single()
  if (jobErr || !job) throw new Error(`Could not seed job: ${jobErr?.message}`)
  jobId = job.id

  // The fourth row has been quiet for 31 days: received then, one note
  // then, nothing since — so every page's "last activity" agrees.
  const quietAt = new Date(Date.now() - QUIET_DAYS * DAY_MS).toISOString()
  const ids: Record<string, string> = {}
  for (const name of NAMES) {
    const { data: candidate, error: candErr } = await db
      .from('candidates')
      .insert({ full_name: candidateName(name), email: `${EMAIL_PREFIX}${name.toLowerCase()}@example.test` })
      .select('id')
      .single()
    if (candErr || !candidate) throw new Error(`Could not seed candidate ${name}: ${candErr?.message}`)
    const quiet = name === 'Dee'
    // No sub_status_key: the 0069 trigger fills it from the stage and source.
    const { data: app, error: appErr } = await db
      .from('applications')
      .insert({
        job_id: jobId,
        company_id: company.id,
        candidate_id: candidate.id,
        stage_key: quiet ? 'screening' : 'new',
        source_key: 'head_hunt',
        ...(quiet ? { received_at: quietAt } : {}),
      })
      .select('id')
      .single()
    if (appErr || !app) throw new Error(`Could not seed application ${name}: ${appErr?.message}`)
    ids[name] = app.id
    if (quiet) {
      const { error: evErr } = await db
        .from('application_events')
        .insert({ application_id: app.id, kind: 'note', body: 'E2E: first call', created_at: quietAt })
      if (evErr) throw new Error(`Could not seed the old event: ${evErr.message}`)
    }
  }
  appIds = { Ana: ids.Ana ?? '', Ben: ids.Ben ?? '', Cal: ids.Cal ?? '', Dee: ids.Dee ?? '' }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

/** The Reports page's "Not responding" attention value for Snowball, once the latest load has landed. */
async function readNotResponding(page: import('@playwright/test').Page): Promise<number> {
  await page.goto('/reports')
  await page.locator('#report-company').selectOption({ label: 'Snowball' })
  await expect(page.locator('.report-ready:not(.dim)')).toBeVisible()
  const tile = page.locator('.attention', { hasText: 'Not responding' })
  await expect(tile).toContainText('Sourced or contacted, no activity in 30 days.')
  const text = (await tile.locator('.kpi-value').textContent())?.trim() ?? ''
  expect(text).toMatch(/^\d+$/)
  return Number(text)
}

test('sub-status badges → bulk Log outreach → not-responding filter → the timeline → the report tile → a stage move takes the default', async ({
  page,
}) => {
  const db = serviceClient()

  // The trigger's defaults: head hunt at new → sourced; at screening → contacted.
  const { data: seeded } = await db
    .from('applications')
    .select('id, stage_key, sub_status_key')
    .eq('job_id', jobId)
  expect(seeded).toHaveLength(4)
  for (const name of ['Ana', 'Ben', 'Cal'] as const) {
    expect(seeded?.find((a) => a.id === appIds[name])?.sub_status_key).toBe('sourced')
  }
  expect(seeded?.find((a) => a.id === appIds.Dee)?.sub_status_key).toBe('contacted')

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // The attention tile counts the quiet row now (the live project carries
  // other quiet rows; the tile is judged by its change, not its absolute).
  const notRespondingBefore = await readNotResponding(page)
  expect(notRespondingBefore).toBeGreaterThanOrEqual(1)

  // The Applications tab: three "Sourced", the fourth "In conversation" + "Not responding".
  await page.goto(`/hiring/jobs/${jobId}?tab=applications`)
  const rowOf = (name: (typeof NAMES)[number]) => page.locator('.application-row', { hasText: candidateName(name) })
  for (const name of ['Ana', 'Ben', 'Cal'] as const) {
    await expect(rowOf(name).locator('.badge')).toHaveText('new')
    await expect(rowOf(name).getByTestId('sub-badge')).toHaveText(LABEL.sourced)
    await expect(rowOf(name).getByTestId('not-responding-badge')).toHaveCount(0)
  }
  await expect(rowOf('Dee').locator('.badge')).toHaveText('screening')
  await expect(rowOf('Dee').getByTestId('sub-badge')).toHaveText(LABEL.contacted)
  await expect(rowOf('Dee').getByTestId('not-responding-badge')).toHaveText('Not responding')

  // Tick two → Log outreach → "Contact attempted", a note → both badges change.
  const bulkButton = page.getByTestId('log-outreach')
  await expect(bulkButton).toBeDisabled()
  await page.getByTestId(`select-app-${appIds.Ana}`).check()
  await page.getByTestId(`select-app-${appIds.Ben}`).check()
  await expect(page.getByTestId('selection-count')).toHaveText('2 selected')
  await expect(bulkButton).toBeEnabled()
  await bulkButton.click()
  const dialog = page.getByTestId('outreach-dialog')
  await expect(dialog).toBeVisible()
  await expect(dialog).toContainText('Log outreach for 2 applications.')
  await expect(dialog.getByTestId('outreach-sub-contacted')).toHaveCount(0) // only the new stage's options
  await dialog.getByTestId('outreach-sub-contact_attempted').check()
  await dialog.getByTestId('outreach-note').fill(VOICEMAIL_NOTE)
  await dialog.getByTestId('outreach-save').click()
  await expect(dialog).toBeHidden()
  await expect(rowOf('Ana').getByTestId('sub-badge')).toHaveText(LABEL.contactAttempted)
  await expect(rowOf('Ben').getByTestId('sub-badge')).toHaveText(LABEL.contactAttempted)
  await expect(rowOf('Cal').getByTestId('sub-badge')).toHaveText(LABEL.sourced)
  await expect(page.getByTestId('selection-count')).toHaveCount(0)

  // DB: one outreach event per application with the note; the rows updated.
  const { data: bulkEvents } = await db
    .from('application_events')
    .select('application_id, kind, body, from_sub_status_key, to_sub_status_key, actor_id')
    .in('application_id', [appIds.Ana, appIds.Ben])
    .eq('kind', 'outreach')
  expect(bulkEvents).toHaveLength(2)
  expect(new Set((bulkEvents ?? []).map((e) => e.application_id))).toEqual(new Set([appIds.Ana, appIds.Ben]))
  for (const e of bulkEvents ?? []) {
    expect(e.body).toBe(VOICEMAIL_NOTE)
    expect(e.from_sub_status_key).toBe('sourced')
    expect(e.to_sub_status_key).toBe('contact_attempted')
    expect(e.actor_id).toBeTruthy()
  }
  const { data: afterBulk } = await db
    .from('applications')
    .select('id, stage_key, sub_status_key')
    .in('id', [appIds.Ana, appIds.Ben, appIds.Cal])
  expect(afterBulk?.find((a) => a.id === appIds.Ana)?.sub_status_key).toBe('contact_attempted')
  expect(afterBulk?.find((a) => a.id === appIds.Ben)?.sub_status_key).toBe('contact_attempted')
  expect(afterBulk?.find((a) => a.id === appIds.Cal)?.sub_status_key).toBe('sourced')
  expect((afterBulk ?? []).every((a) => a.stage_key === 'new')).toBe(true)

  // "Not responding only" leaves the fourth row alone.
  await page.getByTestId('filter-not-responding').check()
  await expect(page.locator('.application-row')).toHaveCount(1)
  await expect(rowOf('Dee')).toBeVisible()
  await page.getByTestId('filter-not-responding').uncheck()
  await expect(page.locator('.application-row')).toHaveCount(4)

  // Open the fourth: the page shows the same badges; log "Interested" from it.
  await page.goto(`/hiring/applications/${appIds.Dee}`)
  await expect(page.getByRole('heading', { name: candidateName('Dee') })).toBeVisible()
  await expect(page.locator('.stage-badge')).toHaveText('screening')
  await expect(page.getByTestId('sub-badge')).toHaveText(LABEL.contacted)
  await expect(page.getByTestId('not-responding-badge')).toHaveText('Not responding')
  await page.getByTestId('log-outreach').click()
  const pageDialog = page.getByTestId('outreach-dialog')
  await expect(pageDialog).toBeVisible()
  await expect(pageDialog).toContainText(`Log outreach for ${candidateName('Dee')}.`)
  await expect(pageDialog.getByTestId('outreach-sub-sourced')).toHaveCount(0) // only the screening stage's options
  await pageDialog.getByTestId('outreach-sub-interested').check()
  await pageDialog.getByTestId('outreach-note').fill(INTERESTED_NOTE)
  await pageDialog.getByTestId('outreach-save').click()
  await expect(pageDialog).toBeHidden()
  await expect(page.getByTestId('sub-badge')).toHaveText(LABEL.interested)
  await expect(page.getByTestId('not-responding-badge')).toHaveCount(0)

  // The timeline: the outreach entry first, phrased from → to with the note.
  const newest = page.locator('.event-row').first()
  await expect(newest.locator('.badge')).toHaveText('Outreach')
  await expect(newest.locator('strong')).toHaveText(`Outreach: ${LABEL.contacted} → ${LABEL.interested} · ${INTERESTED_NOTE}`)
  const { data: deeEvents } = await db
    .from('application_events')
    .select('kind, body, from_sub_status_key, to_sub_status_key')
    .eq('application_id', appIds.Dee)
    .eq('kind', 'outreach')
  expect(deeEvents).toHaveLength(1)
  expect(deeEvents?.[0]?.body).toBe(INTERESTED_NOTE)
  expect(deeEvents?.[0]?.from_sub_status_key).toBe('contacted')
  expect(deeEvents?.[0]?.to_sub_status_key).toBe('interested')
  const { data: dee } = await db.from('applications').select('stage_key, sub_status_key').eq('id', appIds.Dee).single()
  expect(dee?.stage_key).toBe('screening')
  expect(dee?.sub_status_key).toBe('interested')

  // Reports: the fresh event (and "Interested") took the row out of the count.
  const notRespondingAfter = await readNotResponding(page)
  expect(notRespondingAfter).toBe(notRespondingBefore - 1)

  // A plain stage move to screening: the trigger gives the stage's default.
  await page.goto(`/hiring/jobs/${jobId}?tab=applications`)
  await expect(rowOf('Cal').getByTestId('sub-badge')).toHaveText(LABEL.sourced)
  await rowOf('Cal').getByRole('button', { name: 'Move to screening' }).click()
  await expect(rowOf('Cal').locator('.badge')).toHaveText('screening')
  await expect(rowOf('Cal').getByTestId('sub-badge')).toHaveText(LABEL.contacted)
  await expect(rowOf('Cal').getByTestId('not-responding-badge')).toHaveCount(0)
  const { data: cal } = await db.from('applications').select('stage_key, sub_status_key').eq('id', appIds.Cal).single()
  expect(cal?.stage_key).toBe('screening')
  expect(cal?.sub_status_key).toBe('contacted')
  // The move wrote a stage_change, not an outreach event.
  const { count: calOutreach } = await db
    .from('application_events')
    .select('id', { count: 'exact', head: true })
    .eq('application_id', appIds.Cal)
    .eq('kind', 'outreach')
  expect(calOutreach).toBe(0)
})
