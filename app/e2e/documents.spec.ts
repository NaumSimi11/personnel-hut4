import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Documents (plan 026): upload a person document from the profile, open it
 * through a signed link, add a new version (the old one is archived and
 * kept), and upload a company document on the company's Documents tab.
 * Seeds one person at Praedium.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Doc Subject'
const TITLE = 'E2E Employment contract'
const COMPANY_TITLE = 'E2E Company registration'

// The smallest valid PDF Chromium will accept as a file input.
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

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: docs } = await db.from('documents').select('id, storage_path').in('title', [TITLE, COMPANY_TITLE])
  if (docs?.length) {
    await db.storage.from('employee-documents').remove(docs.map((d) => d.storage_path))
    await db.from('documents').update({ supersedes_id: null }).in('id', docs.map((d) => d.id))
    await db.from('documents').delete().in('id', docs.map((d) => d.id))
  }
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    await db.from('employment_periods').delete().in('person_id', ids)
    await db.from('people').delete().in('id', ids)
  }
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id
  const { data: person } = await db.from('people').insert({ full_name: PERSON }).select('id').single()
  personId = person!.id
  const { error } = await db
    .from('employment_periods')
    .insert({ person_id: personId, company_id: companyId, job_title: 'Clerk', status: 'active', start_date: '2024-05-01' })
  if (error) throw new Error(`Could not seed the period: ${error.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('upload → open via signed link → new version archives the old → company document', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // Person document.
  await page.goto(`/people/${personId}`)
  const card = page.locator('.card', { hasText: 'Documents' })
  await card.getByRole('button', { name: 'Add document' }).click()
  await card.locator('#doc-title').fill(TITLE)
  await card.locator('#doc-category').selectOption('employment_agreement')
  await card.locator('#doc-visibility').selectOption('person_and_hr')
  await card.locator('#doc-file').setInputFiles({ name: 'contract.pdf', mimeType: 'application/pdf', buffer: PDF })
  await card.getByRole('button', { name: 'Upload' }).click()
  const row = card.locator('.doc-row', { hasText: TITLE })
  await expect(row).toBeVisible()
  await expect(row).toContainText('Employment agreement')
  await expect(row).toContainText('v1')
  await expect(row).toContainText('The person and HR')

  // Open: a signed, short-lived link to the private object.
  const signedRequests: string[] = []
  page.context().on('request', (r) => {
    // The POST that mints the link has the same path; only the download carries the token.
    if (r.url().includes('/object/sign/employee-documents/') && r.url().includes('token=')) signedRequests.push(r.url())
  })
  const [popup] = await Promise.all([page.waitForEvent('popup'), row.getByRole('button', { name: 'Open' }).click()])
  await expect.poll(() => signedRequests.length).toBeGreaterThan(0)
  expect(signedRequests[0]).toContain('token=')
  await popup.close().catch(() => {})

  // New version: v2 live, v1 archived but kept.
  await row.getByRole('button', { name: 'New version' }).click()
  await card.locator('#doc-file').setInputFiles({ name: 'contract-v2.pdf', mimeType: 'application/pdf', buffer: PDF })
  await card.getByRole('button', { name: 'Upload' }).click()
  await expect(card.locator('.doc-row', { hasText: TITLE })).toHaveCount(1)
  await expect(card.locator('.doc-row', { hasText: TITLE })).toContainText('v2')
  await card.getByRole('button', { name: 'Show archived' }).click()
  await expect(card.locator('.doc-row', { hasText: TITLE })).toHaveCount(2)
  await expect(card.locator('.doc-row.archived', { hasText: TITLE })).toContainText('v1')

  const { data: versions } = await db
    .from('documents')
    .select('version, archived_at, uploaded_by')
    .eq('person_id', personId)
    .order('version')
  expect(versions?.map((v) => [v.version, v.archived_at !== null])).toEqual([
    [1, true],
    [2, false],
  ])
  expect(versions?.every((v) => v.uploaded_by !== null)).toBe(true)

  // Company document on the Documents tab.
  await page.goto(`/companies/${companyId}?tab=documents`)
  await page.getByRole('tab', { name: 'Documents' }).click()
  const companyCard = page.locator('.card', { hasText: 'Company documents' })
  await companyCard.getByRole('button', { name: 'Add document' }).click()
  await companyCard.locator('#doc-title').fill(COMPANY_TITLE)
  await companyCard.locator('#doc-category').selectOption('registration')
  await companyCard.locator('#doc-file').setInputFiles({ name: 'reg.pdf', mimeType: 'application/pdf', buffer: PDF })
  await companyCard.getByRole('button', { name: 'Upload' }).click()
  const companyRow = companyCard.locator('.doc-row', { hasText: COMPANY_TITLE })
  await expect(companyRow).toContainText('Registration & legal')
  await expect(companyRow).toContainText('Everyone in the company')
})
