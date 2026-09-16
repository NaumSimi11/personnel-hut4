import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { answerReason } from './support/dialogs'

/**
 * The employee record (plan 046): one Add employee dialog writes identity,
 * employment, private details and a pay proposal and starts the checklist;
 * the record shows every section; the basics are edited where shown; a
 * department is corrected in place; Company HR (not an admin) sees the
 * private card; the leave entitlement is asked through the app's own
 * dialog, not a browser prompt. Seeds and cleans with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const COMPANY_SHORT_CODE = 'SNOW'

const PERSON = 'E2E Record Employee'
const PERSON_WORK_EMAIL = 'e2e-record-employee@example.test'
const PERSON_PERSONAL_EMAIL = 'e2e-record-home@example.test'
const NATIONAL_ID = '0101990450099'
const DEPARTMENT = 'E2E Records Dept'
const HR_NAME = 'E2E HR Grantee'
const HR_EMAIL = 'e2e-hr-grantee@example.com'
const HR_PASSWORD = 'HrGrantee!2026xyz'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''
let companyName = ''
let hrPersonId = ''

async function removePerson(name: string): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').eq('full_name', name)
  for (const p of people ?? []) {
    const { data: plans } = await db.from('plans').select('id').eq('person_id', p.id)
    const planIds = (plans ?? []).map((x) => x.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', p.id)
    const { data: periods } = await db.from('employment_periods').select('id').eq('person_id', p.id)
    const periodIds = (periods ?? []).map((x) => x.id)
    if (periodIds.length) {
      await db.from('compensation_records').delete().in('employment_period_id', periodIds)
      await db.from('employment_corrections').delete().in('period_id', periodIds)
    }
    const { data: balances } = await db.from('leave_balances').select('id').eq('person_id', p.id)
    if (balances?.length) await db.from('leave_adjustments').delete().in('balance_id', balances.map((b) => b.id))
    await db.from('leave_balances').delete().eq('person_id', p.id)
    await db.from('person_private_details').delete().eq('person_id', p.id)
    await db.from('employment_periods').delete().eq('person_id', p.id)
    const { data: grants } = await db.from('access_grants').select('id').eq('person_id', p.id)
    const grantIds = (grants ?? []).map((g) => g.id)
    if (grantIds.length) await db.from('grant_capabilities').delete().in('grant_id', grantIds)
    await db.from('access_grants').delete().eq('person_id', p.id)
    await db.from('people').delete().eq('id', p.id)
  }
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  await removePerson(PERSON)
  await removePerson(HR_NAME)
  // By email, not by the people row: a seed that failed halfway would otherwise
  // leave an account behind that no later run could remove.
  const { data: users } = await db.auth.admin.listUsers({ page: 1, perPage: 1000 })
  for (const u of users?.users ?? []) if (u.email?.toLowerCase() === HR_EMAIL) await db.auth.admin.deleteUser(u.id)
  await db.from('departments').delete().eq('name', DEPARTMENT)
}

async function seedHr(): Promise<void> {
  const db = serviceClient()
  const { data: user, error: userErr } = await db.auth.admin.createUser({ email: HR_EMAIL, password: HR_PASSWORD, email_confirm: true })
  if (userErr || !user.user) throw new Error(`Could not create the HR account: ${userErr?.message}`)
  const { data: person } = await db.from('people').insert({ full_name: HR_NAME, work_email: HR_EMAIL, user_id: user.user.id }).select('id').single()
  if (!person) throw new Error('Could not seed the HR person')
  hrPersonId = person.id
  await db.from('employment_periods').insert({ person_id: hrPersonId, company_id: companyId, job_title: 'HR Specialist', status: 'active', start_date: '2024-01-01' })
  const { data: preset } = await db.from('permission_presets').select('id').eq('name', 'Company HR').single()
  const { data: grant } = await db.from('access_grants').insert({ person_id: hrPersonId, company_id: companyId, source_preset_id: preset?.id }).select('id').single()
  const { data: caps } = await db.from('preset_capabilities').select('capability_key').eq('preset_id', preset?.id ?? '')
  if (!grant || !caps?.length) throw new Error('Could not grant Company HR')
  await db.from('grant_capabilities').insert(caps.map((c) => ({ grant_id: grant.id, capability_key: c.capability_key })))
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id, name').eq('short_code', COMPANY_SHORT_CODE).single()
  if (!company) throw new Error(`Company ${COMPANY_SHORT_CODE} not found`)
  companyId = company.id
  companyName = company.name
  await seedHr()
})

test.afterAll(cleanup)

test('add with everything → record → edit basics → correct department → HR sees the private card → reason dialog', async ({ browser, page }) => {
  const db = serviceClient()
  const today = new Date().toISOString().slice(0, 10)
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // One dialog, four sections.
  await page.goto('/directory')
  await page.getByTestId('add-employee').click()
  const add = page.getByTestId('add-employee-dialog')
  await add.locator('#ae-name').fill(PERSON)
  await add.locator('#ae-preferred').fill('Rec')
  await add.locator('#ae-work-email').fill(PERSON_WORK_EMAIL)
  await add.locator('#ae-personal-email').fill(PERSON_PERSONAL_EMAIL)
  await add.locator('#ae-phone').fill('+389 70 100 200')
  await add.locator('#ae-company').selectOption({ label: companyName })
  await add.locator('#ae-title').fill('Records Analyst')
  // The department is added inline — HR no longer hits a wall in the second field.
  await add.locator('#ae-new-department').fill(DEPARTMENT)
  await add.getByRole('button', { name: 'Add', exact: true }).click()
  await expect(add.locator('#ae-department')).toContainText(DEPARTMENT)
  const { data: dept } = await db.from('departments').select('id').eq('name', DEPARTMENT).single()
  expect(dept).not.toBeNull()
  await add.locator('#ae-department').selectOption(dept!.id)
  await add.locator('#ae-start').fill(today)
  await expect(add.locator('#ae-onboarding')).toBeChecked()
  await expect(add.getByTestId('section-personal')).toBeVisible()
  await add.locator('#ae-birth').fill('1990-01-01')
  await add.locator('#ae-address').fill('Partizanska 1, Skopje')
  await add.locator('#ae-national-id').fill(NATIONAL_ID)
  await add.locator('#ae-bank').fill('NLB')
  await add.locator('#ae-account').fill('210E2E000099')
  await add.locator('#ae-emergency-name').fill('Petar Record')
  await add.locator('#ae-emergency-relationship').fill('brother')
  await add.locator('#ae-emergency-phone').fill('+389 70 300 400')
  await expect(add.getByTestId('section-pay')).toBeVisible()
  await add.locator('#ae-pay-amount').fill('1234')
  await add.locator('#ae-pay-currency').fill('EUR')
  await add.locator('#ae-pay-basis').selectOption('monthly')
  await add.getByRole('button', { name: 'Create employee' }).click()
  await expect(add.getByRole('heading', { name: /Added\. Employment recorded, the onboarding checklist started, the pay proposal awaits a decision/ })).toBeVisible()
  await add.getByTestId('open-record').click()

  // The record shows every section.
  await expect(page.getByRole('heading', { name: PERSON })).toBeVisible()
  await expect(page.getByTestId('personal-email')).toHaveText(PERSON_PERSONAL_EMAIL)
  await expect(page.locator('.facts-strip')).toContainText(DEPARTMENT)
  const card = page.getByTestId('private-details-card')
  await expect(card.getByTestId('pd-national-id-value')).toHaveText(NATIONAL_ID)
  await expect(card.getByTestId('pd-bank-value')).toHaveText('NLB · 210E2E000099')
  await expect(card.getByTestId('pd-contact-value')).toHaveText('Petar Record · brother · +389 70 300 400')
  const { data: person } = await db.from('people').select('id').eq('full_name', PERSON).single()
  const personId = person!.id
  const { data: plan } = await db.from('plans').select('id, kind').eq('person_id', personId).maybeSingle()
  expect(plan?.kind).toBe('onboarding')
  const { data: period } = await db.from('employment_periods').select('id, department_id').eq('person_id', personId).single()
  expect(period?.department_id).toBe(dept!.id)
  const { data: pay } = await db.from('compensation_records').select('amount, status').eq('employment_period_id', period!.id).single()
  expect(pay).toMatchObject({ amount: 1234, status: 'proposed' })

  // Edit the basics where they are shown.
  await page.getByTestId('edit-details').click()
  const edit = page.getByTestId('edit-person-dialog')
  await edit.locator('#ep-phone').fill('+389 70 999 888')
  await edit.getByRole('button', { name: 'Save details' }).click()
  await expect(page.getByText('Details saved.')).toBeVisible()
  await expect(page.getByTestId('personal-phone')).toHaveText('+389 70 999 888')

  // Correct the department in place (a typo, not a change on a date).
  const empRow = page.locator('.emp-row', { hasText: 'Records Analyst' })
  await empRow.getByRole('button', { name: 'Correct' }).click()
  const correct = page.getByRole('dialog', { name: /Correct/ })
  await correct.locator('#cor-department').selectOption('')
  await correct.locator('#cor-reason').fill('Wrong department picked')
  await correct.getByRole('button', { name: 'Save correction' }).click()
  await expect(page.getByText(/Record corrected/)).toBeVisible()
  const { data: corrected } = await db.from('employment_periods').select('department_id').eq('id', period!.id).single()
  expect(corrected?.department_id).toBeNull()
  const { data: corrections } = await db.from('employment_corrections').select('old_department_id, new_department_id, reason').eq('period_id', period!.id)
  expect(corrections).toHaveLength(1)
  expect(corrections![0]).toMatchObject({ old_department_id: dept!.id, new_department_id: null, reason: 'Wrong department picked' })

  // Company HR — not an admin — sees the private card and may add employees.
  const hr = await browser.newPage()
  await hr.goto('/login')
  await hr.locator('#email').fill(HR_EMAIL)
  await hr.locator('#password').fill(HR_PASSWORD)
  await hr.getByRole('button', { name: 'Sign in' }).click()
  await hr.waitForURL(/\/overview/)
  await hr.goto(`/people/${personId}`)
  await expect(hr.getByTestId('private-details-card').getByTestId('pd-national-id-value')).toHaveText(NATIONAL_ID)
  await hr.goto('/directory')
  await expect(hr.getByTestId('add-employee')).toBeVisible()
  await hr.close()

  // A reason is asked through the app's own dialog — here the leave entitlement.
  await page.goto(`/leave?tab=balances&company=${companyId}`)
  const balance = page.getByTestId(`balance-row-${personId}`)
  await balance.getByRole('button', { name: 'Entitlement' }).click()
  await answerReason(page, 'Yearly entitlement', 20)
  await expect(page.getByText(`Entitlement set for ${PERSON}.`)).toBeVisible()
  await expect(balance.locator('td').nth(1)).toHaveText('20')
})
