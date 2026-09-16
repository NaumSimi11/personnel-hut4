import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Company management: a platform admin creates a company with its full
 * profile (brand + logo, legal & registration, contacts) from the form page,
 * sees it on the list and its profile, edits it, then archives it. "Delete"
 * is archive — the row stays (23 tables reference companies) but leaves every
 * list and picker. Cleans up rows, the seeded director and the uploaded logo
 * with the service client before and after.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''

// Unique per run so a stale row from an aborted run can never collide.
const RUN_ID = Date.now().toString(36).slice(-4).toUpperCase()
const SHORT_CODE = `E2${RUN_ID}`
const NAME = `E2E Company ${RUN_ID}`
const RENAMED = `E2E Company ${RUN_ID} Ltd`
const DIRECTOR_NAME = 'E2E Co Director'
const LEGAL_NAME = `${NAME} d.o.o.`
const ACCENT = '#3e744e'

// 1×1 transparent PNG — enough for a real upload through the storage policy.
const PNG_1PX = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  'base64',
)

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: companies } = await db.from('companies').select('id').like('name', 'E2E Company %')
  for (const c of companies ?? []) {
    const { data: objects } = await db.storage.from('company-logos').list(c.id)
    const paths = (objects ?? []).map((o) => `${c.id}/${o.name}`)
    if (paths.length) await db.storage.from('company-logos').remove(paths)
  }
  await db.from('companies').delete().like('name', 'E2E Company %')
  await db.from('people').delete().eq('full_name', DIRECTOR_NAME)
}

async function seed(): Promise<void> {
  const { error } = await serviceClient().from('people').insert({ full_name: DIRECTOR_NAME })
  if (error) throw new Error(`Could not seed director: ${error.message}`)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('admin creates a full company profile, edits it, then archives it', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.getByRole('link', { name: 'Companies', exact: true }).click()

  // Create — a dedicated page, not a dialog.
  await page.getByRole('link', { name: 'Add company' }).click()
  await expect(page).toHaveURL(/\/companies\/new$/)
  await expect(page.getByRole('heading', { name: 'Add a company.' })).toBeVisible()

  await page.locator('#company-name').fill(NAME)
  await page.locator('#company-code').fill(SHORT_CODE.toLowerCase())
  await page.locator('#company-tagline').fill('Snow for everyone')
  await page.locator('#company-website').fill('snowball.example')
  await page.locator('#company-accent').fill(ACCENT)
  await page
    .locator('#company-logo')
    .setInputFiles({ name: 'logo.png', mimeType: 'image/png', buffer: PNG_1PX })
  await expect(page.locator('.logo-preview img')).toBeVisible()

  await page.locator('#company-legal-name').fill(LEGAL_NAME)
  await page.locator('#company-registration').fill('REG-12345')
  await page.locator('#company-tax-id').fill('MK4030012345678')
  await page.locator('#company-address1').fill('1 Main Street')
  await page.locator('#company-city').fill('Skopje')
  await page.locator('#company-postcode').fill('1000')
  await page.locator('#company-country').fill('North Macedonia')

  await page.locator('#company-director').selectOption({ label: DIRECTOR_NAME })
  await page.locator('#company-email').fill('hello@snowball.example')
  await page.locator('#company-phone').fill('+389 2 000 000')

  await page.getByRole('button', { name: 'Create company' }).click()

  // Lands on the new profile with everything rendered.
  await expect(page).toHaveURL(/\/companies\/[0-9a-f-]{36}$/)
  const companyId = page.url().split('/').pop() ?? ''
  await expect(page.getByRole('heading', { name: NAME })).toBeVisible()
  await expect(page.locator('.company-banner img.logo')).toHaveAttribute(
    'src',
    new RegExp(`company-logos/${companyId}/logo-\\d+\\.png`),
  )
  await expect(page.getByText('Snow for everyone')).toBeVisible()

  const details = page.locator('.card', { hasText: 'Company details' })
  await expect(details).toContainText(LEGAL_NAME)
  await expect(details).toContainText('REG-12345')
  await expect(details).toContainText('1 Main Street')
  await expect(details).toContainText('Skopje')
  await expect(details).toContainText(DIRECTOR_NAME)
  await expect(details).toContainText('hello@snowball.example')
  await expect(details.getByRole('link', { name: 'snowball.example', exact: true })).toHaveAttribute(
    'href',
    'https://snowball.example',
  )

  // The row is a subsidiary of the holding with the logo recorded in brand.
  const { data: created } = await serviceClient()
    .from('companies')
    .select('kind, parent_company_id, brand')
    .eq('id', companyId)
    .single()
  expect(created?.kind).toBe('company')
  expect(created?.parent_company_id).not.toBeNull()
  expect((created?.brand as { logo_path?: string })?.logo_path).toMatch(
    new RegExp(`^${companyId}/logo-\\d+\\.png$`),
  )

  // The list shows the brand too.
  await page.getByRole('link', { name: '← Companies' }).click()
  const card = page.locator('.company-card', { hasText: NAME })
  await expect(card).toBeVisible()
  await expect(card.locator('img.logo')).toBeVisible()
  await expect(card).toContainText(DIRECTOR_NAME)

  // Edit
  await card.click()
  await page.getByRole('link', { name: 'Edit details' }).click()
  await expect(page).toHaveURL(new RegExp(`/companies/${companyId}/edit$`))
  await expect(page.locator('#company-name')).toHaveValue(NAME)
  await expect(page.locator('#company-legal-name')).toHaveValue(LEGAL_NAME)
  await expect(page.locator('.logo-preview img')).toBeVisible()
  await page.locator('#company-name').fill(RENAMED)
  await page.getByRole('button', { name: 'Save changes' }).click()
  await expect(page).toHaveURL(new RegExp(`/companies/${companyId}$`))
  await expect(page.getByRole('heading', { name: RENAMED })).toBeVisible()
  await expect(page.locator('.company-banner img.logo')).toBeVisible()

  // Archive — the in-app dialog names the company, then back to the list.
  await page.getByRole('button', { name: 'Archive this company' }).click()
  await expect(page.getByTestId('reason-dialog')).toContainText(RENAMED)
  await confirmDialog(page)
  await expect(page.getByRole('heading', { level: 1 })).toContainText('One workspace')
  await expect(page.locator('.company-card', { hasText: RENAMED })).toHaveCount(0)

  // …and from pickers elsewhere: the employing-company select on Add employee.
  await page.getByRole('link', { name: 'People & access' }).click()
  await page.getByRole('button', { name: 'Add employee' }).click()
  const companyOptions = page.locator('#ae-company option')
  await expect(companyOptions.first()).toBeAttached()
  await expect(companyOptions.filter({ hasText: RENAMED })).toHaveCount(0)

  // The row still exists, archived — history is never deleted.
  const { data: row } = await serviceClient()
    .from('companies')
    .select('archived_at')
    .eq('id', companyId)
    .single()
  expect(row?.archived_at).not.toBeNull()
})
