import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { answerReason } from './support/dialogs'

/**
 * Checklists (plan 047): the company's onboarding template is customised
 * (a line added — the first edit copies the holding default), an employee
 * added afterwards gets the new line on their checklist, the checklist is
 * worked as checkboxes (tick, untick, add a one-off task, skip with a
 * reason), the queue filters by owner, and a scheduled departure is
 * cancelled from the record. Seeds and cleans with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const COMPANY_SHORT_CODE = 'SNOW'
const PERSON = 'E2E Checklist Starter'
const PERSON_EMAIL = 'e2e-checklist-starter@example.test'
const LINE = 'E2E Parking badge issued'
const ONE_OFF = 'E2E Bring the signed NDA'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

function daysFromNow(days: number): string {
  const d = new Date()
  d.setUTCDate(d.getUTCDate() + days)
  return d.toISOString().slice(0, 10)
}

let companyId = ''
let companyName = ''
let hadOwnTemplate = false

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  for (const p of people ?? []) {
    // Later slices hang more off a person: sends (048), documents and queues (049), notes (050).
    await db.from('notifications').delete().eq('person_id', p.id)
    await db.from('handover_sends').delete().eq('person_id', p.id)
    const { data: docs } = await db.from('documents').select('storage_path').eq('person_id', p.id)
    if (docs?.length) await db.storage.from('employee-documents').remove(docs.map((d) => d.storage_path))
    await db.from('generated_documents').delete().eq('person_id', p.id)
    await db.from('documents').delete().eq('person_id', p.id)
    await db.from('it_requests').delete().eq('person_id', p.id)
    await db.from('asset_assignments').delete().eq('person_id', p.id)
    const { data: plans } = await db.from('plans').select('id').eq('person_id', p.id)
    const planIds = (plans ?? []).map((x) => x.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', p.id)
    const { data: periods } = await db.from('employment_periods').select('id').eq('person_id', p.id)
    const periodIds = (periods ?? []).map((x) => x.id)
    if (periodIds.length) await db.from('employment_departure_details').delete().in('employment_period_id', periodIds)
    await db.from('person_private_details').delete().eq('person_id', p.id)
    await db.from('employment_periods').delete().eq('person_id', p.id)
    await db.from('people').delete().eq('id', p.id)
  }
  // The company template this spec makes: drop it only when the spec created it.
  if (companyId && !hadOwnTemplate) {
    const { data: templates } = await db.from('task_templates').select('id').eq('company_id', companyId).eq('kind', 'onboarding')
    for (const t of templates ?? []) {
      await db.from('plan_tasks').update({ template_task_id: null }).in('template_task_id', (await db.from('template_tasks').select('id').eq('template_id', t.id)).data?.map((x) => x.id) ?? [])
      await db.from('plans').update({ template_id: null }).eq('template_id', t.id)
      await db.from('template_tasks').delete().eq('template_id', t.id)
      await db.from('task_templates').delete().eq('id', t.id)
    }
  } else if (companyId) {
    // An existing company template: only retire the line this spec added.
    const { data: lines } = await db.from('template_tasks').select('id').eq('title', LINE)
    for (const l of lines ?? []) await db.from('template_tasks').delete().eq('id', l.id)
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id, name').eq('short_code', COMPANY_SHORT_CODE).single()
  if (!company) throw new Error(`Company ${COMPANY_SHORT_CODE} not found`)
  companyId = company.id
  companyName = company.name
  const { data: own } = await db.from('task_templates').select('id').eq('company_id', companyId).eq('kind', 'onboarding').eq('active', true)
  hadOwnTemplate = (own ?? []).length > 0
  await cleanup()
})

test.afterAll(cleanup)

test('template line → new employee gets it → tick / untick / add / skip → owner filter → cancel departure', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // Settings → Checklists: add a line; the first edit makes the company's own copy.
  await page.goto(`/companies/${companyId}?tab=settings`)
  const panel = page.getByTestId('checklist-template-panel')
  await expect(panel).toBeVisible()
  await panel.getByTestId('add-template-line').click()
  await panel.locator('#tl-title').fill(LINE)
  await panel.locator('#tl-owner').selectOption('it')
  await panel.locator('#tl-phase').selectOption('before_start')
  await panel.locator('#tl-days').fill('-1')
  await panel.locator('#tl-critical').check()
  await panel.getByRole('button', { name: 'Add line' }).click()
  await expect(panel.getByText('Line added.')).toBeVisible()
  await expect(panel.getByTestId('template-source')).toContainText(`${companyName}'s own onboarding checklist`)
  await expect(panel.locator('.line', { hasText: LINE })).toContainText('IT · 1 day before the start · required')
  const { data: defaultLines } = await db
    .from('template_tasks')
    .select('id, task_templates!inner(company_id)')
    .eq('title', LINE)
    .is('task_templates.company_id', null)
  expect(defaultLines).toHaveLength(0)

  // An employee added now gets the new line on their checklist.
  await page.goto('/directory')
  await page.getByTestId('add-employee').click()
  const add = page.getByTestId('add-employee-dialog')
  await add.locator('#ae-name').fill(PERSON)
  await add.locator('#ae-work-email').fill(PERSON_EMAIL)
  await add.locator('#ae-company').selectOption({ label: companyName })
  await add.locator('#ae-title').fill('Checklist Analyst')
  await add.locator('#ae-start').fill(daysFromNow(7))
  await add.getByRole('button', { name: 'Create employee' }).click()
  await add.getByTestId('open-checklist').click()
  await expect(page).toHaveURL(/\/onboarding\/[0-9a-f-]{36}$/)
  const badgeLine = page.locator('.task-row', { hasText: LINE })
  await expect(badgeLine).toBeVisible()
  await expect(badgeLine).toContainText('Required before start')
  await expect(page.getByTestId('progress-label')).toContainText('0 of 12 done')

  // Tick, untick, tick again.
  await badgeLine.getByRole('checkbox').check()
  await expect(badgeLine.locator('.badge', { hasText: 'done' })).toBeVisible()
  await expect(page.getByTestId('progress-label')).toContainText('1 of 12 done')
  await badgeLine.getByRole('checkbox').uncheck()
  await expect(badgeLine.locator('.badge', { hasText: 'open' })).toBeVisible()
  await badgeLine.getByRole('checkbox').check()
  await expect(badgeLine.locator('.badge', { hasText: 'done' })).toBeVisible()

  // A one-off task for this person only.
  await page.getByTestId('add-task').click()
  await page.getByLabel('New task').fill(ONE_OFF)
  await page.getByLabel('Owner').selectOption('employee')
  await page.getByLabel('Due date').fill(daysFromNow(7))
  await page.getByRole('button', { name: 'Add', exact: true }).click()
  const oneOff = page.locator('.task-row', { hasText: ONE_OFF })
  await expect(oneOff).toBeVisible()
  await expect(oneOff).toContainText('The person')
  await expect(page.getByTestId('progress-label')).toContainText('1 of 13 done')

  // Skip a line with a reason.
  const welcome = page.locator('.task-row', { hasText: 'Welcome note sent with policies' })
  await welcome.locator('summary').click()
  await welcome.getByRole('button', { name: 'Skip' }).click()
  await answerReason(page, 'Sent by hand')
  await expect(welcome.locator('.badge', { hasText: 'skipped' })).toBeVisible()
  await expect(welcome).toContainText('Sent by hand')
  await expect(page.getByTestId('progress-label')).toContainText('2 of 13 done')

  // The queue: the owner filter keeps checklists with an open line for IT; the inline checklist works too.
  await page.goto('/onboarding')
  const { data: person } = await db.from('people').select('id').eq('full_name', PERSON).single()
  const { data: plan } = await db.from('plans').select('id').eq('person_id', person!.id).eq('kind', 'onboarding').single()
  const row = page.getByTestId(`plan-${plan!.id}`)
  await expect(row).toBeVisible()
  await page.getByTestId('owner-filter').selectOption('it')
  await expect(row).toBeVisible()
  await page.getByTestId('owner-filter').selectOption('finance')
  await expect(row).toHaveCount(0)
  await page.getByTestId('owner-filter').selectOption('')
  await row.getByRole('button', { name: /Show .* checklist/ }).click()
  const inline = row.getByTestId(`checklist-${plan!.id}`)
  await expect(inline.getByTestId('progress-label')).toContainText('2 of 13 done')
  await inline.locator('.task-row', { hasText: 'First-day details shared' }).getByRole('checkbox').check()
  await expect(inline.getByTestId('progress-label')).toContainText('3 of 13 done')

  // Schedule a departure, then cancel it: employed again, the checklist on record as cancelled.
  await page.goto(`/people/${person!.id}`)
  const empRow = page.locator('.emp-row', { hasText: 'Checklist Analyst' })
  await empRow.getByRole('button', { name: 'Schedule departure' }).click()
  const dialog = page.getByRole('dialog', { name: /Schedule/ })
  await dialog.locator('#dep-end').fill(daysFromNow(30))
  await dialog.getByRole('button', { name: 'Schedule departure' }).click()
  await expect(empRow).toContainText('Departing')
  await empRow.getByTestId('cancel-departure').click()
  await answerReason(page, 'Staying after all')
  await expect(page.getByText('Departure cancelled.')).toBeVisible()
  await expect(empRow).not.toContainText('Departing')
  await expect(empRow.getByRole('button', { name: 'Schedule departure' })).toBeVisible()
  const { data: period } = await db.from('employment_periods').select('end_date, last_working_date, status').eq('person_id', person!.id).single()
  expect(period).toMatchObject({ end_date: null, last_working_date: null, status: 'pre_start' })
  const { data: off } = await db.from('plans').select('status, cancelled_reason').eq('person_id', person!.id).eq('kind', 'offboarding').single()
  expect(off).toMatchObject({ status: 'cancelled', cancelled_reason: 'Staying after all' })
})
