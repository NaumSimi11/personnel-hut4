import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Company profile (plan 014): the holding list plus one company's tabbed
 * profile — Overview / People / Access / Hiring / Projects / Integrations —
 * with deep-linkable tabs via ?tab=. Seeds against Snowball with the
 * service client and drives the tabs; cleans up before and after.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const COMPANY_SHORT_CODE = 'SNOW'

const PERSON_NAME = 'E2E Co Employee'
const REQUEST_TITLE = 'E2E Co Request'
const PROJECT_NAME = 'E2E Co Project'
const PROJECT_EXTERNAL_ID = 'E2E-CO-1'
const PROVIDER_KEY = 'zoho_projects'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function cleanup(): Promise<void> {
  const db = serviceClient()

  // 1. external_project_members (by project id) → 2. external_projects
  // (by external_id) → 3. employment_periods (by person id) → 4. people
  // (by full_name) → 5. hiring_requests (by title).
  const { data: project } = await db
    .from('external_projects')
    .select('id')
    .eq('external_id', PROJECT_EXTERNAL_ID)
    .maybeSingle()
  if (project) await db.from('external_project_members').delete().eq('project_id', project.id)
  await db.from('external_projects').delete().eq('external_id', PROJECT_EXTERNAL_ID)

  const { data: person } = await db
    .from('people')
    .select('id')
    .eq('full_name', PERSON_NAME)
    .maybeSingle()
  if (person) await db.from('employment_periods').delete().eq('person_id', person.id)
  await db.from('people').delete().eq('full_name', PERSON_NAME)

  await db.from('hiring_requests').delete().eq('title', REQUEST_TITLE)
}

async function seed(): Promise<void> {
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
    job_title: 'Co Tester',
    status: 'active',
    start_date: new Date().toISOString().slice(0, 10),
  })
  if (periodErr) throw new Error(`Could not seed employment period: ${periodErr.message}`)

  const { error: reqErr } = await db.from('hiring_requests').insert({
    company_id: company.id,
    title: REQUEST_TITLE,
    status: 'submitted',
    requested_by: null,
  })
  if (reqErr) throw new Error(`Could not seed hiring request: ${reqErr.message}`)

  const { data: project, error: projectErr } = await db
    .from('external_projects')
    .insert({
      company_id: company.id,
      name: PROJECT_NAME,
      status: 'Active',
      provider_key: PROVIDER_KEY,
      external_id: PROJECT_EXTERNAL_ID,
    })
    .select('id')
    .single()
  if (projectErr || !project) throw new Error(`Could not seed external project: ${projectErr?.message}`)

  const { error: memberErr } = await db.from('external_project_members').insert({
    project_id: project.id,
    person_id: person.id,
  })
  if (memberErr) throw new Error(`Could not seed external project member: ${memberErr.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('companies list → company profile → tabs → deep link', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()

  await page.getByRole('link', { name: 'Companies', exact: true }).click()

  const snowballCard = page.locator('.company-card', { hasText: 'Snowball' })
  await expect(snowballCard).toBeVisible()
  await snowballCard.getByRole('link', { name: 'Open company profile →' }).click()

  // Overview
  await expect(page.getByRole('heading', { name: 'Snowball' })).toBeVisible()
  const metricTiles = page.locator('.metric-tile')
  await expect(metricTiles).toHaveCount(4)
  const peopleTile = metricTiles.filter({ hasText: 'People' })
  await expect(peopleTile.locator('.metric-value')).toHaveText(/^\d+$/)

  // People tab
  await page.getByRole('tab', { name: 'People' }).click()
  const employeeRow = page.locator('tr', { hasText: PERSON_NAME })
  await expect(employeeRow).toBeVisible()
  await expect(employeeRow).toContainText('Co Tester')

  // Access tab — assert the panel renders (rows or the empty state).
  await page.getByRole('tab', { name: 'Access' }).click()
  await expect(page.getByRole('heading', { name: 'Access' })).toBeVisible()

  // Hiring tab
  await page.getByRole('tab', { name: 'Hiring' }).click()
  const requestRow = page.locator('.row', { hasText: REQUEST_TITLE })
  await expect(requestRow).toBeVisible()
  await expect(requestRow.locator('.badge')).toHaveText('submitted')

  // Projects tab
  await page.getByRole('tab', { name: 'Projects' }).click()
  await expect(page.getByText(PROJECT_NAME)).toBeVisible()
  await expect(page.getByText('Project facts stay in the external system. This panel is read-only.')).toBeVisible()

  // Integrations tab
  await page.getByRole('tab', { name: 'Integrations' }).click()
  await expect(page.getByText('Zoho Projects')).toBeVisible()
  const integrationsRow = page.locator('.row', { hasText: 'Zoho Projects' })
  await expect(integrationsRow.locator('.badge')).toBeVisible()

  // Deep link: reload with ?tab=hiring and confirm it stays on Hiring.
  const url = new URL(page.url())
  url.searchParams.set('tab', 'hiring')
  await page.goto(url.toString())
  await expect(page.getByRole('tab', { name: 'Hiring', selected: true })).toBeVisible()
  await expect(page.locator('.row', { hasText: REQUEST_TITLE })).toBeVisible()
})
