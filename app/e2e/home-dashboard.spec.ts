import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Dashboard by role and the Recruitment tabs (plan 044): the admin's Home
 * shows the headline tiles, the applicant pipeline and open positions, the
 * celebrate block with a new teammate, a work anniversary and a birthday
 * (day and month only), kudos posted and removed; the Hiring page lists
 * job openings and applicants across jobs. A plain employee — no grants —
 * sees none of the team facts, only what was addressed to them. Seeds its
 * own rows and cleans them with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const COMPANY_SHORT_CODE = 'SNOW'

const NEWCOMER = 'E2E Dash Newcomer'
const VETERAN = 'E2E Dash Veteran'
const JOB_TITLE = 'E2E Dash Job'
const CANDIDATE = 'E2E Dash Candidate'
const CANDIDATE_EMAIL = 'e2e-dash-candidate@example.test'
const KUDOS = 'E2E kudos: thanks for the smooth launch!'
const EMPLOYEE = 'E2E Dash Employee'
const EMPLOYEE_EMAIL = 'e2e-dash-employee@example.com'
const EMPLOYEE_PASSWORD = 'DashEmployee!2026xyz'
const EMPLOYEE_KUDOS = 'E2E kudos: welcome to the team!'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

function shiftDate(days: number, years = 0): string {
  const d = new Date()
  d.setUTCFullYear(d.getUTCFullYear() + years)
  d.setUTCDate(d.getUTCDate() + days)
  return d.toISOString().slice(0, 10)
}

let companyId = ''
let jobId = ''
let applicationId = ''
let adminPersonId = ''
let employeeId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').in('full_name', [NEWCOMER, VETERAN, EMPLOYEE])
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    await db.from('kudos').delete().or(`from_person_id.in.(${ids.join(',')}),to_person_id.in.(${ids.join(',')})`)
    await db.from('person_private_details').delete().in('person_id', ids)
    await db.from('employment_periods').delete().in('person_id', ids)
    await db.from('people').delete().in('id', ids)
  }
  // By email, not by the people row: a seed that failed halfway would otherwise
  // leave an account behind that no later run could remove.
  const { data: users } = await db.auth.admin.listUsers({ page: 1, perPage: 1000 })
  for (const u of users?.users ?? []) if (u.email?.toLowerCase() === EMPLOYEE_EMAIL) await db.auth.admin.deleteUser(u.id)
  const { data: jobs } = await db.from('jobs').select('id').eq('title', JOB_TITLE)
  for (const j of jobs ?? []) {
    await db.from('applications').delete().eq('job_id', j.id)
    await db.from('jobs').delete().eq('id', j.id)
  }
  await db.from('candidates').delete().eq('email', CANDIDATE_EMAIL)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', COMPANY_SHORT_CODE).single()
  if (!company) throw new Error(`Company ${COMPANY_SHORT_CODE} not found`)
  companyId = company.id

  const { data: newcomer } = await db.from('people').insert({ full_name: NEWCOMER, work_email: 'e2e-dash-newcomer@example.test' }).select('id').single()
  const { data: veteran } = await db.from('people').insert({ full_name: VETERAN, work_email: 'e2e-dash-veteran@example.test' }).select('id').single()
  if (!newcomer || !veteran) throw new Error('Could not seed people')
  await db.from('employment_periods').insert([
    { person_id: newcomer.id, company_id: companyId, job_title: 'Dash Designer', status: 'active', start_date: shiftDate(-5) },
    { person_id: veteran.id, company_id: companyId, job_title: 'Dash Analyst', status: 'active', start_date: shiftDate(2, -1) },
  ])
  await db.from('person_private_details').insert({ person_id: veteran.id, birth_date: shiftDate(3, -25) })

  const { data: job } = await db.from('jobs').insert({ company_id: companyId, title: JOB_TITLE, status: 'ready' }).select('id').single()
  const { data: candidate } = await db.from('candidates').insert({ full_name: CANDIDATE, email: CANDIDATE_EMAIL }).select('id').single()
  if (!job || !candidate) throw new Error('Could not seed the job and candidate')
  jobId = job.id
  const { data: application } = await db
    .from('applications')
    .insert({ job_id: jobId, company_id: companyId, candidate_id: candidate.id, stage_key: 'screening' })
    .select('id')
    .single()
  if (!application) throw new Error('Could not seed the application')
  applicationId = application.id
  // Tomorrow's interview, for the upcoming-interviews card (plan 067); it goes with the application.
  await db.from('interviews').insert({
    application_id: applicationId,
    company_id: companyId,
    kind: 'technical',
    scheduled_at: new Date(Date.now() + 86_400_000).toISOString(),
  })

  // A plain employee: an account, an employment, no grants anywhere.
  const { data: admin } = await db.from('people').select('id').ilike('work_email', ADMIN_EMAIL).single()
  if (!admin) throw new Error('Could not find the test user\'s person row')
  adminPersonId = admin.id
  const { data: user, error: userErr } = await db.auth.admin.createUser({
    email: EMPLOYEE_EMAIL,
    password: EMPLOYEE_PASSWORD,
    email_confirm: true,
    app_metadata: { must_change_password: false },
  })
  if (userErr || !user.user) throw new Error(`Could not create the employee's account: ${userErr?.message}`)
  const { data: employee } = await db
    .from('people')
    .insert({ full_name: EMPLOYEE, work_email: EMPLOYEE_EMAIL, user_id: user.user.id })
    .select('id')
    .single()
  if (!employee) throw new Error('Could not seed the employee')
  employeeId = employee.id
  await db
    .from('employment_periods')
    .insert({ person_id: employeeId, company_id: companyId, job_title: 'Dash Assistant', status: 'active', start_date: shiftDate(-200) })
  await db.from('kudos').insert({ from_person_id: adminPersonId, to_person_id: employeeId, message: EMPLOYEE_KUDOS })
})

test.afterAll(cleanup)

test('Home: tiles, pipeline, open positions, celebrate; kudos posted and removed', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  const stats = page.getByTestId('dashboard-stats')
  await expect(stats.getByTestId('stat-active')).toContainText('Active employees')
  await expect(stats.getByTestId('stat-away')).toContainText('Away today')
  await expect(stats.getByTestId('stat-applicants')).toContainText('Applicants in progress')

  const recruitment = page.getByTestId('recruitment-snapshot')
  await expect(recruitment.getByText('Applicant pipeline')).toBeVisible()
  await expect(recruitment.locator(`a[href="/hiring/jobs/${jobId}"]`)).toContainText('1 needed')
  // The upcoming interview links to the same application, so scope to the applicants card.
  const recent = recruitment.locator('.card', { has: page.getByRole('heading', { name: 'Recent applicants' }) })
  await expect(recent.locator(`a[href="/hiring/applications/${applicationId}"]`)).toContainText('Screening')

  // The hiring board (plan 067): one row for the seeded job, its one candidate
  // drawn as the furthest stage, the row opening the job's applicants.
  const boardRow = recruitment.getByTestId(`board-row-${jobId}`)
  await expect(boardRow).toContainText(JOB_TITLE)
  await expect(boardRow).toContainText('not live yet')
  await expect(boardRow.locator('.arrow')).toHaveText('1')
  await expect(boardRow).toHaveAttribute('href', `/hiring/jobs/${jobId}?tab=applications`)
  await expect(recruitment.getByTestId('upcoming-interviews').locator('li', { hasText: CANDIDATE })).toContainText('Tomorrow')

  const celebrate = page.getByTestId('celebrate')
  await expect(celebrate.locator('li.row', { hasText: NEWCOMER })).toContainText('Started')
  const veteranRows = celebrate.locator('li.row', { hasText: VETERAN })
  await expect(veteranRows.filter({ hasText: '1 year' })).toContainText('In 2 days')
  const birthday = veteranRows.filter({ hasText: 'In 3 days' })
  await expect(birthday).toBeVisible()
  await expect(birthday).not.toContainText(/\d{4}/)

  // Kudos to the newcomer lands on the wall and can be removed by the giver.
  await page.locator('#kudos-to').selectOption({ label: `${NEWCOMER} · Snowball` })
  await page.locator('#kudos-message').fill(KUDOS)
  await page.getByRole('button', { name: 'Post kudos' }).click()
  const wall = page.getByTestId('kudos-wall')
  const entry = wall.locator('li.kudos', { hasText: KUDOS })
  await expect(entry).toContainText(`→ ${NEWCOMER}`)
  await entry.getByRole('button', { name: 'Remove' }).click()
  await expect(wall.locator('li.kudos', { hasText: KUDOS })).toHaveCount(0)
})

test('Hiring: Job openings and Applicants tabs list across jobs, with filters', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto('/hiring?tab=openings')
  const opening = page.getByTestId(`opening-${jobId}`)
  await expect(opening).toContainText(JOB_TITLE)
  await expect(opening).toContainText('Ready')
  await expect(opening.locator('td').nth(4)).toHaveText('1') // in play

  await page.getByTestId('hiring-tab-applicants').click()
  await expect(page).toHaveURL(/tab=applicants/)
  const applicant = page.getByTestId(`applicant-${applicationId}`)
  await expect(applicant).toContainText(CANDIDATE)
  await expect(applicant).toContainText('Screening')
  await page.getByLabel('Stage').selectOption('rejected')
  await expect(page.getByTestId(`applicant-${applicationId}`)).toHaveCount(0)
  await page.getByLabel('Stage').selectOption('live')
  await page.getByLabel('Search applicants').fill('nobody-matches-this')
  await expect(page.getByTestId('applicants')).toContainText('No applicants match')
})

test('a plain employee sees none of the team facts — only the kudos addressed to them', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(EMPLOYEE_EMAIL)
  await page.locator('#password').fill(EMPLOYEE_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // No people.view, no candidates.view, no jobs.view, no leave.view: no tiles, no panels.
  await expect(page.getByTestId('stat-active')).toHaveCount(0)
  await expect(page.getByTestId('stat-away')).toHaveCount(0)
  await expect(page.getByTestId('stat-applicants')).toHaveCount(0)
  await expect(page.getByTestId('recruitment-snapshot')).toHaveCount(0)
  await expect(page.getByTestId('away-today')).toHaveCount(0)
  const celebrate = page.getByTestId('celebrate')
  await expect(celebrate.getByRole('heading', { name: 'Birthdays' })).toHaveCount(0)
  await expect(celebrate.getByRole('heading', { name: 'New teammates' })).toHaveCount(0)
  await expect(celebrate.getByRole('heading', { name: 'Fun corner' })).toHaveCount(0)

  // What was given to them is theirs to read — and not theirs to remove.
  const entry = page.getByTestId('kudos-wall').locator('li.kudos', { hasText: EMPLOYEE_KUDOS })
  await expect(entry).toContainText(`→ ${EMPLOYEE}`)
  await expect(entry.getByRole('button', { name: 'Remove' })).toHaveCount(0)
  // Nobody to thank: the colleague list is empty and the form says why.
  await expect(page.getByTestId('kudos-form')).toContainText('You can thank colleagues whose records you may see')
  await expect(page.locator('#kudos-to')).toBeDisabled()
})
