import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Kudos values and the Kudos page (plan 051): HR records a kudos on a
 * colleague's behalf with a value and a date, the wall on Home shows the
 * value as a pill, the row is edited and removed from the Kudos page; an
 * admin adds a value and retires it.
 * Seeds two people at Praedium.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const GIVER = 'E2E Kudos Giver'
const RECEIVER = 'E2E Kudos Receiver'
const MESSAGE = 'E2E kudos: carried the release on their own'
const EDITED = 'E2E kudos: carried the whole release on their own'
const VALUE = 'E2E Craft'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').in('full_name', [GIVER, RECEIVER])
  const ids = (people ?? []).map((p) => p.id)
  if (ids.length) {
    await db.from('kudos').delete().or(`from_person_id.in.(${ids.join(',')}),to_person_id.in.(${ids.join(',')})`)
    await db.from('employment_periods').delete().in('person_id', ids)
    await db.from('people').delete().in('id', ids)
  }
  await db.from('kudos_values').delete().eq('name', VALUE)
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id
  for (const name of [GIVER, RECEIVER]) {
    const { data: person } = await db.from('people').insert({ full_name: name }).select('id').single()
    const { error } = await db
      .from('employment_periods')
      .insert({ person_id: person!.id, company_id: companyId, job_title: 'Kudos Clerk', status: 'active', start_date: '2024-01-15' })
    if (error) throw new Error(`Could not seed ${name}: ${error.message}`)
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

test('a value added → kudos recorded on behalf with the value and a date → pill on the wall → edited → removed → value retired', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.getByTestId('nav-kudos').click()
  await page.waitForURL(/\/kudos/)
  const pageEl = page.getByTestId('kudos-page')

  // The five defaults are there; an admin adds one.
  const values = page.getByTestId('kudos-values-panel')
  await expect(values.getByTestId('kudos-value-row').filter({ hasText: 'Teamwork' })).toHaveCount(1)
  await values.getByTestId('kudos-value-add').click()
  await values.locator('#kv-name').fill(VALUE)
  await values.locator('#kv-description').fill('Did it properly.')
  await values.getByRole('button', { name: 'Add' }).click()
  await expect(values).toContainText(`"${VALUE}" added`)
  await expect(values.getByTestId('kudos-value-row').filter({ hasText: VALUE })).toContainText('0 kudos')

  // Recorded on the giver's behalf, dated last week, tagged with the new value.
  await pageEl.getByTestId('kudos-add').click()
  const form = page.getByTestId('kudos-admin-form')
  await form.locator('#ka-from').selectOption({ label: GIVER })
  await form.locator('#ka-to').selectOption({ label: RECEIVER })
  await form.locator('#ka-date').fill('2026-09-10')
  await form.locator('#ka-value').selectOption({ label: VALUE })
  await form.locator('#ka-message').fill(MESSAGE)
  await form.getByRole('button', { name: 'Add kudos' }).click()
  await expect(page.getByTestId('kudos-notice')).toContainText(`Kudos to ${RECEIVER} is on the wall`)
  const row = page.getByTestId('kudos-admin-row').filter({ hasText: MESSAGE })
  await expect(row).toContainText(`${GIVER} → ${RECEIVER}`)
  await expect(row).toContainText(VALUE)
  await expect(row).toContainText('10 Sep')
  await expect(row).toContainText('recorded by')
  await expect(values.getByTestId('kudos-value-row').filter({ hasText: VALUE })).toContainText('1 kudos')

  // The month filter keeps September 2026.
  await page.getByTestId('kudos-month').selectOption({ value: '2026-09' })
  await expect(page.getByTestId('kudos-admin-row').filter({ hasText: MESSAGE })).toHaveCount(1)
  await page.getByTestId('kudos-month').selectOption({ value: '' })

  // The wall on Home shows the pill.
  await page.goto('/overview')
  const wallEntry = page.getByTestId('kudos-wall').locator('li.kudos', { hasText: MESSAGE })
  await expect(wallEntry.getByTestId('kudos-value-pill')).toHaveText(VALUE)

  // Edited, then removed.
  await page.getByTestId('nav-kudos').click()
  await page.waitForURL(/\/kudos/)
  await page.getByTestId('kudos-admin-row').filter({ hasText: MESSAGE }).getByRole('button', { name: 'Edit' }).click()
  const edit = page.getByTestId('kudos-edit-form')
  await edit.locator('input[maxlength="280"]').fill(EDITED)
  await edit.getByRole('button', { name: 'Save' }).click()
  await expect(page.getByTestId('kudos-notice')).toContainText('Kudos updated')
  const edited = page.getByTestId('kudos-admin-row').filter({ hasText: EDITED })
  await expect(edited).toHaveCount(1)
  await edited.getByRole('button', { name: 'Remove' }).click()
  await confirmDialog(page)
  await expect(page.getByTestId('kudos-admin-row').filter({ hasText: EDITED })).toHaveCount(0)

  // The value retires and leaves the picker.
  await values.getByTestId('kudos-value-row').filter({ hasText: VALUE }).getByRole('button', { name: 'Retire' }).click()
  await expect(values).toContainText(`"${VALUE}" retired`)
  await expect(values.getByTestId('kudos-value-row').filter({ hasText: VALUE })).toContainText('retired')
  await pageEl.getByTestId('kudos-add').click()
  await expect(page.getByTestId('kudos-admin-form').locator('#ka-value option', { hasText: VALUE })).toHaveCount(0)
})
