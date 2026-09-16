import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Equipment on the offboarding checklist and rehire (plan 033): a leaver
 * holding a laptop gets a return task when the departure is scheduled;
 * returning the laptop completes it; after they are former, Rehire on the
 * profile opens a new period pre-filled from the old one.
 * Seeds one person at Praedium with an issued laptop.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Rehire Subject'
const TAG = `E2E-RH-${Date.now().toString(36).toUpperCase()}`
const END_DATE = '2030-04-30'
const LAST_DAY = '2030-04-26'

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
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (company) {
    const { data: assets } = await db.from('assets').select('id').eq('company_id', company.id).like('asset_tag', 'E2E-RH-%')
    const ids = (assets ?? []).map((a) => a.id)
    if (ids.length) {
      await db.from('plan_tasks').update({ asset_id: null }).in('asset_id', ids)
      await db.from('asset_assignments').delete().in('asset_id', ids)
      await db.from('assets').delete().in('id', ids)
    }
  }
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    const { data: plans } = await db.from('plans').select('id').in('person_id', ids)
    const planIds = (plans ?? []).map((p) => p.id)
    if (planIds.length) {
      await db.from('plan_tasks').delete().in('plan_id', planIds)
      await db.from('plans').delete().in('id', planIds)
    }
    const { data: periods } = await db.from('employment_periods').select('id').in('person_id', ids)
    const periodIds = (periods ?? []).map((p) => p.id)
    if (periodIds.length) await db.from('employment_departure_details').delete().in('employment_period_id', periodIds)
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
  const { error } = await db.from('employment_periods').insert({
    person_id: personId,
    company_id: companyId,
    job_title: 'Field Engineer',
    employment_type_key: 'part_time',
    status: 'active',
    start_date: '2024-05-01',
  })
  if (error) throw new Error(`Could not seed the period: ${error.message}`)
  const { data: asset, error: assetErr } = await db
    .from('assets')
    .insert({ company_id: companyId, asset_tag: TAG, type_key: 'laptop', model: 'MacBook Air' })
    .select('id')
    .single()
  if (assetErr || !asset) throw new Error(`Could not seed the asset: ${assetErr?.message}`)
  // The service role bypasses the register guard; assignment via direct insert keeps status in step.
  const { error: assignErr } = await db
    .from('asset_assignments')
    .insert({ asset_id: asset.id, person_id: personId, reserved_at: new Date().toISOString(), issued_at: new Date().toISOString() })
  if (assignErr) throw new Error(`Could not seed the assignment: ${assignErr.message}`)
  await db.from('assets').update({ status: 'assigned' }).eq('id', asset.id)
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('departure adds a return task → return completes it → former → rehire', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // Schedule the departure from the profile.
  await page.goto(`/people/${personId}`)
  const empRow = page.locator('.emp-row', { hasText: 'Field Engineer · Praedium' })
  await empRow.getByRole('button', { name: 'Schedule departure' }).click()
  const dialog = page.getByRole('dialog')
  await dialog.locator('#dep-end').fill(END_DATE)
  await dialog.locator('#dep-last').fill(LAST_DAY)
  await dialog.getByRole('button', { name: 'Schedule departure' }).click()
  await expect(empRow).toContainText('Departing')

  // The plan carries a critical IT task for the laptop.
  await page.getByRole('link', { name: 'Open offboarding plan' }).click()
  const returnTask = page.locator('.task-row', { hasText: `Return ${TAG} · Laptop MacBook Air` })
  await expect(returnTask).toBeVisible()
  await expect(returnTask.locator('.badge', { hasText: 'open' })).toBeVisible()

  // Take the laptop back on the Equipment tab: the task completes itself.
  await page.goto(`/companies/${companyId}?tab=equipment`)
  await page.getByRole('tab', { name: 'Equipment' }).click()
  const assetRow = page.locator('.asset-row', { hasText: TAG })
  await assetRow.getByRole('button', { name: 'Return' }).click()
  await page.locator('#return-condition').fill('Good')
  await page.getByRole('button', { name: 'Confirm return' }).click()
  await expect(assetRow).toContainText('Available')
  const { data: task } = await db.from('plan_tasks').select('status, done_by').like('title', `Return ${TAG}%`).single()
  expect(task?.status).toBe('done')
  expect(task?.done_by).not.toBeNull()

  // Mark former, then rehire from the profile.
  await page.goto(`/people/${personId}`)
  await empRow.getByRole('button', { name: 'Mark as former' }).click()
  await confirmDialog(page)
  await expect(page.getByText(/now former/i)).toBeVisible()
  await page.getByRole('button', { name: 'Rehire' }).click()
  await expect(page.locator('#emp-title')).toHaveValue('Field Engineer')
  await page.locator('#emp-title').fill('Senior Field Engineer')
  // The old period runs to its end date; the form already proposes the day after.
  await expect(page.locator('#emp-start')).toHaveValue('2030-05-01')
  await page.locator('.add-emp').getByRole('button', { name: 'Save' }).click()
  await expect(page.getByText(/Rehired/)).toBeVisible()
  await expect(page.locator('.emp-row', { hasText: 'Senior Field Engineer · Praedium' }).locator('.badge', { hasText: 'pre start' })).toBeVisible()
  const { data: periods } = await db.from('employment_periods').select('job_title, status').eq('person_id', personId).order('start_date')
  expect(periods?.map((p) => [p.job_title, p.status])).toEqual([
    ['Field Engineer', 'former'],
    ['Senior Field Engineer', 'pre_start'],
  ])
})
