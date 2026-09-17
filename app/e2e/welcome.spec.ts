import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Policies as a library and the welcome note (plan 050): HR writes a text
 * policy for the company and publishes it, sets the first-day details, adds
 * an employee with an account; the welcome note previews the policy and
 * the details; Send queues it to the personal address, files a PDF and
 * ticks the line; the person signs in, reads the policy inline and
 * acknowledges; "Policies acknowledged" ticks itself. Seeds and cleans.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const COMPANY_SHORT_CODE = 'SNOW'
const PERSON = 'E2E Welcome Starter'
const PERSON_EMAIL = 'e2e-welcome-starter@example.com'
const PERSON_PERSONAL = 'e2e-welcome-home@example.test'
const PERSON_PASSWORD = 'Welcome!2026xyz'
const POLICY = 'E2E Desk policy'
const POLICY_TEXT = 'Keep your desk tidy at the end of the day. Lock your screen when you leave it.'

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
let firstDayBefore: unknown = null

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: policies } = await db.from('policies').select('id').eq('title', POLICY)
  for (const p of policies ?? []) {
    await db.from('policy_acknowledgements').delete().eq('policy_id', p.id)
    await db.from('policies').delete().eq('id', p.id)
  }
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  for (const p of people ?? []) {
    await db.from('policy_acknowledgements').delete().eq('person_id', p.id)
    await db.from('notifications').delete().eq('person_id', p.id)
    const { data: docs } = await db.from('documents').select('storage_path').eq('person_id', p.id)
    if (docs?.length) await db.storage.from('employee-documents').remove(docs.map((d) => d.storage_path))
    await db.from('generated_documents').delete().eq('person_id', p.id)
    await db.from('documents').delete().eq('person_id', p.id)
    await db.from('handover_sends').delete().eq('person_id', p.id)
    await db.from('it_requests').delete().eq('person_id', p.id)
    const { data: plans } = await db.from('plans').select('id').eq('person_id', p.id)
    const planIds = (plans ?? []).map((x) => x.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', p.id)
    await db.from('person_private_details').delete().eq('person_id', p.id)
    await db.from('employment_periods').delete().eq('person_id', p.id)
    await db.from('people').delete().eq('id', p.id)
  }
  const { data: users } = await db.auth.admin.listUsers({ page: 1, perPage: 1000 })
  for (const u of users?.users ?? []) if (u.email?.toLowerCase() === PERSON_EMAIL) await db.auth.admin.deleteUser(u.id)
  if (companyId && firstDayBefore !== null) {
    const { data: c } = await db.from('companies').select('settings').eq('id', companyId).single()
    const settings = (c?.settings ?? {}) as Record<string, unknown>
    const next = { ...settings }
    if (firstDayBefore === undefined) delete next.first_day
    else next.first_day = firstDayBefore
    await db.from('companies').update({ settings: next }).eq('id', companyId)
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id, name, settings').eq('short_code', COMPANY_SHORT_CODE).single()
  if (!company) throw new Error(`Company ${COMPANY_SHORT_CODE} not found`)
  companyId = company.id
  companyName = company.name
  firstDayBefore = (company.settings as Record<string, unknown>).first_day
  await cleanup()
})

test.afterAll(cleanup)

test('text policy → first-day details → welcome note sent and filed → the person acknowledges → the line ticks', async ({ browser, page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // A text policy for the company, published without a file.
  await page.goto(`/companies/${companyId}?tab=documents`)
  const policies = page.locator('.card', { hasText: 'Policies' })
  await policies.getByRole('button', { name: 'Add policy' }).click()
  await policies.locator('#pol-title').fill(POLICY)
  await policies.locator('#pol-summary').fill('Desks and screens')
  await policies.locator('#pol-body').fill(POLICY_TEXT)
  await policies.getByRole('button', { name: 'Save draft' }).click()
  const row = policies.locator('.policy-row', { hasText: POLICY })
  await expect(row).toBeVisible()
  await row.getByRole('button', { name: 'Publish', exact: true }).click()
  await expect(row).toContainText('published')
  const { data: policy } = await db.from('policies').select('id, status, storage_path, body').eq('title', POLICY).single()
  expect(policy).toMatchObject({ status: 'published', storage_path: null, body: POLICY_TEXT })
  await row.getByTestId(`read-${policy!.id}`).click()
  await expect(row.getByTestId(`body-${policy!.id}`)).toContainText('Lock your screen')

  // First-day details for the company.
  await page.goto(`/companies/${companyId}?tab=settings`)
  const firstDay = page.getByTestId('first-day-panel')
  await firstDay.locator('#fd-where').fill('E2E Reception, floor 3')
  await firstDay.locator('#fd-when').fill('09:00')
  await firstDay.locator('#fd-ask').fill('Ana')
  await firstDay.locator('#fd-bring').fill('ID card')
  await firstDay.getByRole('button', { name: 'Save' }).click()
  await expect(firstDay.getByText('First-day details saved.')).toBeVisible()

  // A hire with a personal address.
  await page.goto('/directory')
  await page.getByTestId('add-employee').click()
  const add = page.getByTestId('add-employee-dialog')
  await add.locator('#ae-name').fill(PERSON)
  await add.locator('#ae-preferred').fill('Wel')
  await add.locator('#ae-work-email').fill(PERSON_EMAIL)
  await add.locator('#ae-personal-email').fill(PERSON_PERSONAL)
  await add.locator('#ae-company').selectOption({ label: companyName })
  await add.locator('#ae-title').fill('Welcome Analyst')
  await add.locator('#ae-start').fill(daysFromNow(10))
  await add.getByRole('button', { name: 'Create employee' }).click()
  await add.getByTestId('open-checklist').click()

  // The welcome note previews the details and the policy; Send ticks the line and files the PDF.
  const card = page.getByTestId('welcome-card')
  await card.getByRole('button', { name: 'Preview' }).click()
  const preview = card.getByTestId('welcome-preview')
  await expect(preview).toContainText('Dear Wel,')
  await expect(preview).toContainText('Where: E2E Reception, floor 3')
  await expect(preview).toContainText(`• ${POLICY} — Desks and screens`)
  await expect(card.getByTestId('welcome-sent')).toHaveText('Not sent yet.')
  await expect(card.getByTestId('welcome-to')).toHaveValue('personal')
  await card.getByTestId('welcome-send').click()
  await expect(card.getByTestId('welcome-sent')).toContainText('to the personal email')
  const welcomeLine = page.locator('.task-row', { hasText: 'Welcome note sent with policies' })
  await expect(welcomeLine.locator('.badge', { hasText: 'done' })).toBeVisible()
  const { data: person } = await db.from('people').select('id').eq('full_name', PERSON).single()
  const { data: note } = await db.from('notifications').select('email_to, email_status, title').eq('person_id', person!.id).eq('kind', 'welcome.note').single()
  expect(note?.email_to).toBe(PERSON_PERSONAL)
  expect(note?.title).toBe(`Welcome to ${companyName}, Wel`)
  await expect
    .poll(async () => (await db.from('generated_documents').select('status').eq('person_id', person!.id).eq('kind', 'welcome_note').maybeSingle()).data?.status, { timeout: 20000 })
    .toBe('done')
  const { data: pdf } = await db.from('documents').select('category_key, mime_type').eq('person_id', person!.id).eq('category_key', 'welcome_note').single()
  expect(pdf?.mime_type).toBe('application/pdf')
  const policiesLine = page.locator('.task-row', { hasText: 'Policies acknowledged' })
  await expect(policiesLine.locator('.badge', { hasText: 'open' })).toBeVisible()

  // The person gets an account, signs in, reads the policy inline and acknowledges everything that applies.
  const { data: user, error: userErr } = await db.auth.admin.createUser({ email: PERSON_EMAIL, password: PERSON_PASSWORD, email_confirm: true })
  if (userErr || !user.user) throw new Error(`Could not create the account: ${userErr?.message}`)
  await db.from('people').update({ user_id: user.user.id }).eq('id', person!.id)
  const me = await browser.newPage()
  await me.goto('/login')
  await me.locator('#email').fill(PERSON_EMAIL)
  await me.locator('#password').fill(PERSON_PASSWORD)
  await me.getByRole('button', { name: 'Sign in' }).click()
  await me.waitForURL(/\/overview/)
  await me.goto('/me')
  const myPolicies = me.locator('.card', { hasText: 'Policies' })
  await myPolicies.getByTestId(`my-read-${policy!.id}`).click()
  await expect(myPolicies.getByTestId(`my-body-${policy!.id}`)).toContainText('Keep your desk tidy')
  // Acknowledge every policy that applies (the holding's published ones too).
  const buttons = myPolicies.getByRole('button', { name: 'I have read this' })
  while ((await buttons.count()) > 0) {
    await buttons.first().click()
    await expect(myPolicies.getByText('You are up to date.')).toBeVisible({ timeout: 10000 }).catch(() => undefined)
    if ((await buttons.count()) === 0) break
  }
  await expect(myPolicies.getByText('You are up to date.')).toBeVisible()
  await me.close()

  // The line ticked itself.
  await page.reload()
  await expect(page.locator('.task-row', { hasText: 'Policies acknowledged' }).locator('.badge', { hasText: 'done' })).toBeVisible()
})
