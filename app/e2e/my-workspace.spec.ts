import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * My workspace: the signed-in person's own profile, onboarding plan, open
 * tasks, access grants, and project assignments (plan 013). The signed-in
 * test user is a platform admin whose own person row has no employment
 * period — that is realistic for this page and is not "fixed" here. This
 * spec seeds a *separate* person with an onboarding plan that has one task
 * assigned to the admin, so "My tasks" has deterministic content, without
 * ever touching the admin's own person/grant rows. Runs against the live
 * Supabase project; cleans up with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const COMPANY_SHORT_CODE = 'SNOW'
const PERSON_NAME = 'E2E MW Starter'
const TASK_FOR_ADMIN = 'E2E MW Task For Admin'
const OTHER_TASK = 'E2E MW Other Task'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

function daysFromNow(days: number): string {
  const d = new Date()
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

const START_DATE = daysFromNow(7)

let adminPersonId = ''
let adminFullName = ''
let adminWorkEmail: string | null = null

async function findAdminPerson(): Promise<{
  id: string
  full_name: string
  work_email: string | null
}> {
  const db = serviceClient()
  const { data, error } = await db
    .from('people')
    .select('id, full_name, work_email')
    .eq('work_email', ADMIN_EMAIL)
    .single()
  if (error || !data) {
    throw new Error(`Could not find the admin's person row by TEST_USER_EMAIL: ${error?.message}`)
  }
  return data
}

async function cleanup(): Promise<void> {
  const db = serviceClient()

  // 1. plan_tasks (by plan id) → 2. plans (by person id) →
  // 3. employment_periods (by person id) → 4. people (by full_name).
  const { data: person } = await db
    .from('people')
    .select('id')
    .eq('full_name', PERSON_NAME)
    .maybeSingle()
  if (person) {
    const { data: plans } = await db.from('plans').select('id').eq('person_id', person.id)
    const planIds = (plans ?? []).map((p) => p.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', person.id)
    await db.from('employment_periods').delete().eq('person_id', person.id)
  }
  await db.from('people').delete().eq('full_name', PERSON_NAME)
}

async function seed(adminId: string): Promise<void> {
  const db = serviceClient()

  const { data: company, error: companyErr } = await db
    .from('companies')
    .select('id')
    .eq('short_code', COMPANY_SHORT_CODE)
    .single()
  if (companyErr || !company) {
    throw new Error(`Could not find Snowball company: ${companyErr?.message}`)
  }

  const { data: person, error: personErr } = await db
    .from('people')
    .insert({ full_name: PERSON_NAME })
    .select('id')
    .single()
  if (personErr || !person) throw new Error(`Could not seed person: ${personErr?.message}`)

  const { error: periodErr } = await db.from('employment_periods').insert({
    person_id: person.id,
    company_id: company.id,
    job_title: 'Starter',
    status: 'pre_start',
    start_date: START_DATE,
  })
  if (periodErr) throw new Error(`Could not seed employment period: ${periodErr.message}`)

  const { data: plan, error: planErr } = await db
    .from('plans')
    .insert({
      kind: 'onboarding',
      person_id: person.id,
      company_id: company.id,
      start_date: START_DATE,
      status: 'in_progress',
    })
    .select('id')
    .single()
  if (planErr || !plan) throw new Error(`Could not seed plan: ${planErr?.message}`)

  const { error: tasksErr } = await db.from('plan_tasks').insert([
    {
      plan_id: plan.id,
      title: TASK_FOR_ADMIN,
      owner_id: adminId,
      owner_role: 'hr',
      phase_key: 'before_start',
      critical: false,
      status: 'open',
      sort_order: 10,
    },
    {
      plan_id: plan.id,
      title: OTHER_TASK,
      owner_role: 'it',
      phase_key: 'before_start',
      critical: true,
      status: 'open',
      sort_order: 20,
    },
  ])
  if (tasksErr) throw new Error(`Could not seed plan tasks: ${tasksErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  const admin = await findAdminPerson()
  adminPersonId = admin.id
  adminFullName = admin.full_name
  adminWorkEmail = admin.work_email
  await cleanup()
  await seed(adminPersonId)
})

test.afterAll(async () => {
  await cleanup()
})

test('my workspace shows my profile, my tasks, access, and projects', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()

  await page.getByRole('link', { name: 'My workspace', exact: true }).click()

  // Step 2: profile card shows the admin's name and work email.
  const profileCard = page.locator('.card', { hasText: 'My profile' })
  await expect(profileCard).toContainText(adminFullName)
  if (adminWorkEmail) await expect(profileCard).toContainText(adminWorkEmail)

  // Step 3: My tasks has the task assigned to the admin, not the other one.
  const tasksCard = page.locator('.tasks-card')
  await expect(tasksCard).toContainText(TASK_FOR_ADMIN)
  await expect(tasksCard).not.toContainText(OTHER_TASK)

  // Step 4: mark it complete → it disappears from My tasks.
  const taskRow = tasksCard.locator('.task-row', { hasText: TASK_FOR_ADMIN })
  await taskRow.getByRole('button', { name: 'Mark complete' }).click()
  await expect(tasksCard.locator('.task-row', { hasText: TASK_FOR_ADMIN })).toHaveCount(0)

  // Step 5: access card shows the platform-admin note.
  const accessCard = page.locator('.card', { hasText: 'My access' })
  await expect(accessCard).toContainText(
    'You are a platform admin: full access across every company.',
  )

  // Step 6: projects card renders (rows or the empty state, either way).
  await expect(page.getByRole('heading', { name: 'My projects' })).toBeVisible()
})
