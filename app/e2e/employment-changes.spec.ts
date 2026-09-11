import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Employment changes (plan 022): an immediate change applies to the record,
 * a future one is scheduled and can be cancelled, circular reporting is
 * refused, departments are managed on the company's Structure tab, and the
 * directory filters by employment state. Seeds two people at Praedium.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Change Subject'
const MANAGER = 'E2E Change Manager'
const DEPARTMENT = 'E2E Logistics'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let personId = ''
let managerId = ''
let companyId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').in('full_name', [PERSON, MANAGER])
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    const { data: periods } = await db.from('employment_periods').select('id').in('person_id', ids)
    const periodIds = (periods ?? []).map((p) => p.id)
    if (periodIds.length) await db.from('employment_changes').delete().in('employment_period_id', periodIds)
    await db.from('employment_periods').delete().in('person_id', ids)
    await db.from('people').delete().in('id', ids)
  }
  await db.from('departments').delete().eq('name', DEPARTMENT)
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id
  for (const [name, title] of [
    [PERSON, 'Warehouse Lead'],
    [MANAGER, 'Operations Director'],
  ] as const) {
    const { data: person } = await db.from('people').insert({ full_name: name }).select('id').single()
    await db.from('employment_periods').insert({
      person_id: person!.id,
      company_id: company.id,
      job_title: title,
      status: 'active',
      start_date: '2024-03-01',
    })
    if (name === PERSON) personId = person!.id
    else managerId = person!.id
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('structure → immediate change → scheduled change → cycle refused → directory filters', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // Structure: add a department to Praedium.
  await page.goto(`/companies/${companyId}?tab=structure`)
  await page.getByRole('tab', { name: 'Structure' }).click()
  const departments = page.locator('.card', { hasText: 'Departments' })
  await departments.locator('#new-department').fill(DEPARTMENT)
  await departments.getByRole('button', { name: 'Add department' }).click()
  await expect(departments.locator('.structure-row', { hasText: DEPARTMENT })).toBeVisible()

  // Immediate change: title + department + manager, effective today.
  await page.goto(`/people/${personId}`)
  const row = page.locator('.emp-row', { hasText: 'Warehouse Lead · Praedium' })
  await row.getByRole('button', { name: 'Schedule change' }).click()
  const dialog = page.getByRole('dialog')
  await dialog.locator('#chg-title').fill('Logistics Lead')
  await dialog.locator('#chg-department').selectOption({ label: DEPARTMENT })
  await dialog.locator('#chg-manager').selectOption({ label: MANAGER })
  await dialog.locator('#chg-reason').fill('Promotion after the peak season')
  await dialog.getByRole('button', { name: 'Save change' }).click()
  await expect(page.getByText('Change applied')).toBeVisible()
  const updated = page.locator('.emp-row', { hasText: 'Logistics Lead · Praedium' })
  await expect(updated).toBeVisible()
  await expect(updated).toContainText(DEPARTMENT)
  await expect(updated).toContainText(`reports to ${MANAGER}`)
  await expect(page.locator('.profile-head')).toContainText(`Manager: ${MANAGER}`)

  const { data: period } = await db
    .from('employment_periods')
    .select('job_title, manager_id, department:departments(name)')
    .eq('person_id', personId)
    .single()
  expect(period?.job_title).toBe('Logistics Lead')
  expect(period?.manager_id).toBe(managerId)

  // Future change: recorded as scheduled, record untouched, cancellable.
  await updated.getByRole('button', { name: 'Schedule change' }).click()
  await dialog.locator('#chg-effective').fill('2030-01-01')
  await dialog.locator('#chg-title').fill('Head of Logistics')
  await dialog.getByRole('button', { name: 'Save change' }).click()
  await expect(page.getByText('Change scheduled for 2030-01-01')).toBeVisible()
  const pending = page.locator('.pending-change', { hasText: 'Head of Logistics' })
  await expect(pending).toBeVisible()
  await expect(page.locator('.emp-row', { hasText: 'Logistics Lead · Praedium' })).toBeVisible()
  page.once('dialog', (d) => d.accept())
  await pending.getByRole('button', { name: 'Cancel' }).click()
  await expect(pending).toHaveCount(0)

  // Circular reporting: the manager cannot report to their own report.
  await page.goto(`/people/${managerId}`)
  await page.locator('.emp-row', { hasText: 'Operations Director' }).getByRole('button', { name: 'Schedule change' }).click()
  await dialog.locator('#chg-manager').selectOption({ label: PERSON })
  await dialog.getByRole('button', { name: 'Save change' }).click()
  await expect(dialog.getByRole('alert')).toContainText('circular')

  // Directory filters: the subject is active; "Former" hides them.
  await page.goto('/directory')
  await page.getByRole('button', { name: 'Active', exact: true }).click()
  await expect(page.locator('tr', { hasText: PERSON })).toBeVisible()
  await page.getByRole('button', { name: 'Former', exact: true }).click()
  await expect(page.locator('tr', { hasText: PERSON })).toHaveCount(0)
})
