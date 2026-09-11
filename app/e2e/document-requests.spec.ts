import { createClient } from '@supabase/supabase-js'
import { expect, test, type Page } from '@playwright/test'

/**
 * Document requests and policies (plan 028): HR requests a document, the
 * employee signs in and submits it from My workspace, HR accepts; HR
 * publishes a policy, the employee acknowledges it, HR sees the count.
 * Seeds one employee at Praedium with a real sign-in.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const RUN_ID = Date.now().toString(36)
const PERSON = 'E2E Request Subject'
const PERSON_EMAIL = `e2e-request-subject-${RUN_ID}@example.test`
const PERSON_PASSWORD = `Subject-${RUN_ID}-pass!`
const POLICY_TITLE = 'E2E Code of conduct'

const PDF = Buffer.from(
  '%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n' +
    '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n',
)

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''
let personId = ''
let userId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: policies } = await db.from('policies').select('id, storage_path').eq('title', POLICY_TITLE)
  if (policies?.length) {
    await db.from('policy_acknowledgements').delete().in('policy_id', policies.map((p) => p.id))
    const paths = policies.map((p) => p.storage_path).filter((p): p is string => !!p)
    if (paths.length) await db.storage.from('policies').remove(paths)
    await db.from('policies').delete().in('id', policies.map((p) => p.id))
  }
  const { data: people } = await db.from('people').select('id, user_id').eq('full_name', PERSON)
  for (const p of people ?? []) {
    await db.from('document_requests').delete().eq('person_id', p.id)
    const { data: docs } = await db.from('documents').select('id, storage_path').eq('person_id', p.id)
    if (docs?.length) {
      await db.storage.from('employee-documents').remove(docs.map((d) => d.storage_path))
      await db.from('documents').update({ supersedes_id: null }).in('id', docs.map((d) => d.id))
      await db.from('documents').delete().in('id', docs.map((d) => d.id))
    }
    await db.from('employment_periods').delete().eq('person_id', p.id)
    await db.from('people').delete().eq('id', p.id)
    if (p.user_id) await db.auth.admin.deleteUser(p.user_id)
  }
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id
  const { data: user, error: userErr } = await db.auth.admin.createUser({
    email: PERSON_EMAIL,
    password: PERSON_PASSWORD,
    email_confirm: true,
    app_metadata: { must_change_password: false },
  })
  if (userErr || !user.user) throw new Error(`Could not create the employee's account: ${userErr?.message}`)
  userId = user.user.id
  const { data: person, error: personErr } = await db
    .from('people')
    .insert({ full_name: PERSON, work_email: PERSON_EMAIL, user_id: userId })
    .select('id')
    .single()
  if (personErr || !person) throw new Error(`Could not seed the person: ${personErr?.message}`)
  personId = person.id
  const { error } = await db
    .from('employment_periods')
    .insert({ person_id: personId, company_id: companyId, job_title: 'Analyst', status: 'active', start_date: '2024-02-01' })
  if (error) throw new Error(`Could not seed the period: ${error.message}`)
}

async function signIn(page: Page, email: string, password: string): Promise<void> {
  await page.goto('/login')
  await page.locator('#email').fill(email)
  await page.locator('#password').fill(password)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('HR requests → employee submits → HR accepts; policy published → acknowledged → counted', async ({ browser, page }) => {
  const db = serviceClient()
  await signIn(page, ADMIN_EMAIL, ADMIN_PASSWORD)

  // HR requests an identification document.
  await page.goto(`/people/${personId}`)
  const requests = page.locator('.card', { hasText: 'Document requests' })
  await requests.getByRole('button', { name: 'Request a document' }).click()
  await requests.locator('#req-category').selectOption('identification')
  await requests.locator('#req-due').fill('2030-01-31')
  await requests.locator('#req-note').fill('Passport or ID card, both sides')
  await requests.getByRole('button', { name: 'Send request' }).click()
  const requestRow = requests.locator('.request-row', { hasText: 'Identification' })
  await expect(requestRow).toContainText('Waiting for the document')
  await expect(requestRow).toContainText('due 2030-01-31')

  // The employee signs in and submits it from My workspace.
  const employeeContext = await browser.newContext()
  const employee = await employeeContext.newPage()
  await signIn(employee, PERSON_EMAIL, PERSON_PASSWORD)
  await employee.goto('/me')
  const mine = employee.locator('.card', { hasText: 'Requested from you' })
  const mineRow = mine.locator('.request-row', { hasText: 'Identification' })
  await expect(mineRow).toContainText('Passport or ID card, both sides')
  await mineRow.locator('input[type="file"]').setInputFiles({ name: 'id.pdf', mimeType: 'application/pdf', buffer: PDF })
  await mineRow.getByRole('button', { name: 'Submit' }).click()
  await expect(mineRow).toContainText('Submitted — awaiting review')

  const { data: submitted } = await db
    .from('document_requests')
    .select('status, document:documents!document_requests_fulfilled_document_id_fkey(visibility, uploaded_by)')
    .eq('person_id', personId)
    .single()
  expect(submitted?.status).toBe('submitted')
  const doc = submitted?.document as unknown as { visibility: string; uploaded_by: string } | null
  expect(doc?.visibility).toBe('person_and_hr')
  expect(doc?.uploaded_by).toBe(personId)

  // HR accepts.
  await page.reload()
  await expect(requestRow).toContainText('Submitted — awaiting review')
  await requestRow.getByRole('button', { name: 'Accept' }).click()
  await expect(requestRow).toContainText('Accepted')

  // HR publishes a company policy.
  await page.goto(`/companies/${companyId}?tab=documents`)
  await page.getByRole('tab', { name: 'Documents' }).click()
  const policies = page.locator('.card', { hasText: 'Policies' })
  await policies.getByRole('button', { name: 'Add policy' }).click()
  await policies.locator('#pol-title').fill(POLICY_TITLE)
  await policies.locator('#pol-file').setInputFiles({ name: 'conduct.pdf', mimeType: 'application/pdf', buffer: PDF })
  await policies.getByRole('button', { name: 'Save draft' }).click()
  const policyRow = policies.locator('.policy-row', { hasText: POLICY_TITLE })
  await expect(policyRow).toContainText('Draft')
  await policyRow.getByRole('button', { name: 'Publish' }).click()
  await expect(policyRow).toContainText('v1')
  await expect(policyRow).toContainText('0 acknowledged')

  // The employee acknowledges it.
  await employee.goto('/me')
  const toRead = employee.locator('.card', { hasText: 'Policies' })
  const policyToRead = toRead.locator('.policy-row', { hasText: POLICY_TITLE })
  await expect(policyToRead).toContainText('Please read and acknowledge')
  await policyToRead.getByRole('button', { name: 'I have read this' }).click()
  await expect(policyToRead).toContainText('Acknowledged')
  await employeeContext.close()

  await page.reload()
  await expect(page.locator('.policy-row', { hasText: POLICY_TITLE })).toContainText('1 acknowledged')
  const { data: acks } = await db
    .from('policy_acknowledgements')
    .select('version, person_id')
    .eq('person_id', personId)
  expect(acks).toEqual([{ version: 1, person_id: personId }])
})
