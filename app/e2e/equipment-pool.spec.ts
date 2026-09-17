import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Equipment for the holding (plan 049): an asset added to the pool from the
 * Equipment page is issued to someone in a company, the handover form is
 * generated as a PDF under their documents; a scheduled departure lists it
 * on the return tasks and generates the return form; a fresh hire's
 * checklist carries the starter kit, ticking every item ticks the line.
 * Seeds and cleans with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const COMPANY_SHORT_CODE = 'SNOW'
const PERSON = 'E2E Pool Holder'
const PERSON_EMAIL = 'e2e-pool-holder@example.test'
const TAG = 'E2E-POOL-01'
const BUCKET = 'employee-documents'

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

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  for (const p of people ?? []) {
    const { data: docs } = await db.from('documents').select('id, storage_path').eq('person_id', p.id)
    if (docs?.length) await db.storage.from(BUCKET).remove(docs.map((d) => d.storage_path))
    await db.from('generated_documents').delete().eq('person_id', p.id)
    await db.from('documents').delete().eq('person_id', p.id)
    await db.from('handover_sends').delete().eq('person_id', p.id)
    await db.from('it_requests').delete().eq('person_id', p.id)
    const { data: plans } = await db.from('plans').select('id').eq('person_id', p.id)
    const planIds = (plans ?? []).map((x) => x.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', p.id)
    await db.from('asset_assignments').delete().eq('person_id', p.id)
    const { data: periods } = await db.from('employment_periods').select('id').eq('person_id', p.id)
    const periodIds = (periods ?? []).map((x) => x.id)
    if (periodIds.length) await db.from('employment_departure_details').delete().in('employment_period_id', periodIds)
    await db.from('person_private_details').delete().eq('person_id', p.id)
    await db.from('employment_periods').delete().eq('person_id', p.id)
    await db.from('people').delete().eq('id', p.id)
  }
  const { data: assets } = await db.from('assets').select('id').eq('asset_tag', TAG)
  for (const a of assets ?? []) {
    await db.from('plan_tasks').delete().eq('asset_id', a.id)
    await db.from('asset_assignments').delete().eq('asset_id', a.id)
    await db.from('assets').delete().eq('id', a.id)
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id, name').eq('short_code', COMPANY_SHORT_CODE).single()
  if (!company) throw new Error(`Company ${COMPANY_SHORT_CODE} not found`)
  companyId = company.id
  companyName = company.name
  await cleanup()
})

test.afterAll(cleanup)

test('pool asset → issued across companies → handover PDF → kit ticks the line → departure lists it and makes the return form', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // A fresh hire in the company: the checklist opens the starter kit request.
  await page.goto('/directory')
  await page.getByTestId('add-employee').click()
  const add = page.getByTestId('add-employee-dialog')
  await add.locator('#ae-name').fill(PERSON)
  await add.locator('#ae-work-email').fill(PERSON_EMAIL)
  await add.locator('#ae-company').selectOption({ label: companyName })
  await add.locator('#ae-title').fill('Pool Analyst')
  await add.locator('#ae-start').fill(daysFromNow(5))
  await add.getByRole('button', { name: 'Create employee' }).click()
  await add.getByTestId('open-checklist').click()
  const kit = page.getByTestId('starter-kit-card')
  await expect(kit).toBeVisible()
  const { data: person } = await db.from('people').select('id').eq('full_name', PERSON).single()
  const { data: req } = await db.from('it_requests').select('id, requested_systems').eq('person_id', person!.id).eq('kind', 'onboarding').single()
  const items = req!.requested_systems as { item: string }[]
  expect(items.length).toBeGreaterThanOrEqual(3)
  const kitLine = page.locator('.task-row', { hasText: 'Starter kit issued' })
  await expect(kitLine.locator('.badge', { hasText: 'open' })).toBeVisible()

  // Add a pool asset from the Equipment page and reserve + issue it to the hire.
  await page.getByTestId('nav-equipment').click()
  await expect(page).toHaveURL(/\/equipment$/)
  await page.getByTestId('add-asset').click()
  await page.locator('#asset-owner').selectOption('__pool__')
  await page.locator('#asset-tag').fill(TAG)
  await page.locator('#asset-type').selectOption('laptop')
  await page.locator('#asset-model').fill('ThinkPad X1')
  await page.getByRole('button', { name: 'Save asset' }).click()
  const row = page.getByTestId(`asset-${TAG}`)
  await expect(row).toBeVisible()
  await expect(row).toContainText('Holding pool')
  await row.getByRole('button', { name: 'Reserve' }).click()
  await page.locator('#reserve-person').selectOption({ label: PERSON })
  await page.getByRole('button', { name: 'Confirm reservation' }).click()
  await expect(row).toContainText('Reserved')
  await row.getByRole('button', { name: 'Issue' }).click()
  await expect(row).toContainText('Assigned')

  // The handover form was queued and generated as a PDF under the person's documents.
  await expect
    .poll(async () => (await db.from('generated_documents').select('status').eq('person_id', person!.id).eq('kind', 'equipment_handover').maybeSingle()).data?.status, { timeout: 20000 })
    .toBe('done')
  const { data: handover } = await db.from('documents').select('id, storage_path, category_key, mime_type, size_bytes, uploaded_by').eq('person_id', person!.id).eq('category_key', 'equipment_handover').single()
  expect(handover?.mime_type).toBe('application/pdf')
  expect(handover?.size_bytes ?? 0).toBeGreaterThan(1000)
  const { data: file } = await db.storage.from(BUCKET).download(handover!.storage_path)
  expect(file).not.toBeNull()
  expect(Buffer.from(await file!.arrayBuffer()).subarray(0, 5).toString()).toBe('%PDF-')

  // Back on the checklist: issue every kit item; the line ticks itself.
  const { data: plan } = await db.from('plans').select('id').eq('person_id', person!.id).eq('kind', 'onboarding').single()
  await page.goto(`/onboarding/${plan!.id}`)
  for (let i = 0; i < items.length; i++) {
    await kit.getByTestId(`kit-line-${i}`).getByRole('checkbox').check()
    await expect(kit.getByTestId(`kit-line-${i}`)).toContainText('Issued')
  }
  await expect(kit.locator('.badge', { hasText: 'Issued' })).toBeVisible()
  await expect(kitLine.locator('.badge', { hasText: 'done' })).toBeVisible()

  // Schedule the departure: the pool laptop is on the return list, the return form is generated.
  await page.goto(`/people/${person!.id}`)
  const empRow = page.locator('.emp-row', { hasText: 'Pool Analyst' })
  await empRow.getByRole('button', { name: 'Schedule departure' }).click()
  const dialog = page.getByRole('dialog', { name: /Schedule/ })
  await dialog.locator('#dep-end').fill(daysFromNow(40))
  await dialog.getByRole('button', { name: 'Schedule departure' }).click()
  await expect(empRow).toContainText('Departing')
  await page.getByRole('link', { name: 'Open offboarding plan' }).click()
  await expect(page.locator('.task-row', { hasText: `Return ${TAG}` })).toBeVisible()
  await expect
    .poll(async () => (await db.from('generated_documents').select('status').eq('person_id', person!.id).eq('kind', 'equipment_return').maybeSingle()).data?.status, { timeout: 20000 })
    .toBe('done')
  const { data: ret } = await db.from('documents').select('id, version, title').eq('person_id', person!.id).eq('category_key', 'equipment_return').single()
  expect(ret?.version).toBe(1)
  expect(ret?.title).toContain('Equipment return form')
})
