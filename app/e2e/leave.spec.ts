import { createClient } from '@supabase/supabase-js'
import { expect, test, type Page } from '@playwright/test'

/**
 * Leave (plan 036): HR imports a holiday, sets an entitlement, an employee
 * requests leave and sees the working days (holiday excluded), the request
 * lands on the Home queue and the Requests tab, HR approves, the balance
 * moves, the calendar shows the entry, and the employee cancels before the
 * start. Seeds one employee at Praedium with an account.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const PERSON = 'E2E Leave Taker'
const PERSON_EMAIL = 'e2e-leave-taker@example.com'
const PERSON_PASSWORD = 'LeaveTaker!2026xyz'
const HOLIDAY = 'E2E Holiday'
// A Monday–Friday window at least four weeks ahead (so "cancel before the
// start" holds), kept inside the current balance year; the Wednesday becomes
// a holiday. Late in the year the window is pulled back to the first full
// week of December — still in the future until the second week.
const YEAR = new Date().getUTCFullYear()
function nextMondayAfter(days: number): Date {
  const d = new Date()
  d.setUTCHours(0, 0, 0, 0)
  d.setUTCDate(d.getUTCDate() + days)
  d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7))
  return d
}
const monday = nextMondayAfter(28)
if (monday.getUTCFullYear() !== YEAR) {
  monday.setTime(Date.UTC(YEAR, 11, 1))
  monday.setUTCDate(1 + ((8 - monday.getUTCDay()) % 7))
}
const iso = (d: Date, plus: number) => new Date(d.getTime() + plus * 86_400_000).toISOString().slice(0, 10)
const MONDAY = iso(monday, 0)
const WEDNESDAY = iso(monday, 2)
const FRIDAY = iso(monday, 4)
const MONTH_LABEL = new Date(`${MONDAY}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })
const WEDNESDAY_TEXT = `${new Date(`${WEDNESDAY}T00:00:00Z`).getUTCDate()} ${MONTH_LABEL.split(' ')[0]}`

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let companyId = ''
let personId = ''
let previousCountry: string | null | undefined

async function cleanup(): Promise<void> {
  const db = serviceClient()
  await db.from('public_holidays').delete().eq('name', HOLIDAY)
  const { data: people } = await db.from('people').select('id, user_id').eq('full_name', PERSON)
  for (const p of people ?? []) {
    await db.from('leave_requests').delete().eq('person_id', p.id)
    const { data: balances } = await db.from('leave_balances').select('id').eq('person_id', p.id)
    if (balances?.length) await db.from('leave_adjustments').delete().in('balance_id', balances.map((b) => b.id))
    await db.from('leave_balances').delete().eq('person_id', p.id)
    await db.from('employment_periods').delete().eq('person_id', p.id)
    await db.from('people').delete().eq('id', p.id)
    if (p.user_id) await db.auth.admin.deleteUser(p.user_id)
  }
  if (companyId && previousCountry !== undefined) {
    await db.from('companies').update({ country_code: previousCountry }).eq('id', companyId)
  }
}

async function seed(): Promise<void> {
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id, country_code').eq('short_code', 'PRAE').single()
  if (!company) throw new Error('Praedium not found')
  companyId = company.id
  previousCountry = company.country_code
  await db.from('companies').update({ country_code: 'MK' }).eq('id', companyId)
  const { data: user, error: userErr } = await db.auth.admin.createUser({
    email: PERSON_EMAIL,
    password: PERSON_PASSWORD,
    email_confirm: true,
    app_metadata: { must_change_password: false },
  })
  if (userErr || !user.user) throw new Error(`Could not create the employee's account: ${userErr?.message}`)
  const { data: person, error: personErr } = await db
    .from('people')
    .insert({ full_name: PERSON, work_email: PERSON_EMAIL, user_id: user.user.id })
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

/** Answer the next window.prompt / confirm calls in order. */
function answerDialogs(page: Page, answers: string[]): void {
  const queue = [...answers]
  page.on('dialog', (d) => void d.accept(queue.shift() ?? ''))
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
  await seed()
})

test.afterAll(async () => {
  await cleanup()
})

test('holiday import → entitlement → request (holiday excluded) → queue → approve → calendar → cancel', async ({ browser, page }) => {
  const db = serviceClient()
  await signIn(page, ADMIN_EMAIL, ADMIN_PASSWORD)

  // HR pastes the programme: the parser reads "<day> <Month>, E2E Holiday".
  await page.goto(`/leave?tab=holidays&company=${companyId}`)
  await page.getByText(/Paste the official programme/).click()
  await page.locator('textarea').fill(`${WEDNESDAY_TEXT}, ${HOLIDAY}`)
  await page.getByRole('button', { name: 'Preview' }).click()
  await expect(page.locator('.preview')).toContainText(`${WEDNESDAY} — ${HOLIDAY}`)
  await page.getByRole('button', { name: /^Import 1$/ }).click()
  await expect(page.getByText(/1 holidays imported for MK/)).toBeVisible()
  await expect(page.locator('tr', { hasText: HOLIDAY })).toContainText(WEDNESDAY)

  // Entitlement for the employee: 20 days this year.
  await page.goto(`/leave?tab=balances&company=${companyId}`)
  const row = page.getByTestId(`balance-row-${personId}`)
  await expect(row).toContainText('No')
  answerDialogs(page, ['20', 'Yearly entitlement'])
  await row.getByRole('button', { name: 'Entitlement' }).click()
  await expect(page.getByText(`Entitlement set for ${PERSON}.`)).toBeVisible()
  await expect(row.locator('td').nth(1)).toHaveText('20')
  page.removeAllListeners('dialog')

  // The employee requests Monday–Friday: 5 weekdays minus every MK holiday in the window
  // (ours plus whatever the real calendar holds there).
  const { data: offDays } = await db.from('public_holidays').select('date').eq('country_code', 'MK').gte('date', MONDAY).lte('date', FRIDAY)
  const DAYS = 5 - new Set((offDays ?? []).map((h) => h.date)).size
  const employee = await browser.newPage()
  await signIn(employee, PERSON_EMAIL, PERSON_PASSWORD)
  await employee.goto('/me')
  await employee.getByTestId(`request-leave-${companyId}`).click()
  const dialog = employee.getByRole('dialog')
  await dialog.locator('#lv-start').fill(MONDAY)
  await dialog.locator('#lv-end').fill(FRIDAY)
  await expect(dialog.getByTestId('working-days-preview')).toHaveText(String(DAYS))
  await dialog.locator('#lv-note').fill('Winter break')
  await dialog.getByRole('button', { name: 'Send request' }).click()
  await expect(employee.getByText(`Sent for approval: ${DAYS} working days.`)).toBeVisible()
  const rail = employee.getByTestId(`balance-${companyId}`)
  await expect(rail).toContainText('20')
  await expect(rail.locator('.stat', { hasText: 'pending' })).toContainText(String(DAYS))

  // HR sees it on the Home queue; the link lands on the Requests tab.
  await page.goto('/overview')
  const queueRow = page.locator('.queue-row', { hasText: `Leave: ${PERSON}` })
  await expect(queueRow).toContainText('awaiting your decision')
  await queueRow.getByRole('link', { name: 'Decide' }).click()
  await expect(page).toHaveURL(/\/leave\?.*tab=requests/)
  const pending = page.locator('.req-row', { hasText: PERSON })
  await expect(pending).toContainText(`${DAYS} working days`)
  await pending.getByRole('button', { name: 'Approve' }).click()
  await expect(page.locator('details .req-row', { hasText: PERSON }).locator('.badge')).toHaveText('Approved')

  const { data: approved } = await db.from('leave_requests').select('status, working_days, carry_over_days_used').eq('person_id', personId).single()
  expect(approved).toMatchObject({ status: 'approved', working_days: DAYS })

  // The company calendar shows the entry on the Wednesday-free week.
  await page.goto(`/leave?tab=calendar&company=${companyId}`)
  for (let i = 0; i < 12 && (await page.locator('.card-head h2').first().textContent())?.trim() !== MONTH_LABEL; i += 1) {
    await page.getByRole('button', { name: 'Next ›' }).click()
  }
  // The entry shows on a working day of the week — the first one that is not a holiday.
  const off = new Set((offDays ?? []).map((h) => h.date))
  const workDay = [0, 1, 3, 4].map((d) => iso(monday, d)).find((d) => !off.has(d)) ?? MONDAY
  await expect(page.locator(`.day[data-date="${workDay}"] .entry`)).toContainText(`${PERSON} · annual`)
  await expect(page.locator(`.day[data-date="${WEDNESDAY}"]`)).toContainText(HOLIDAY)
  await expect(page.locator(`.day[data-date="${WEDNESDAY}"] .entry`)).toHaveCount(0)

  // The employee's balance moved, and they cancel before the start.
  await employee.reload()
  await expect(rail.locator('.stat', { hasText: 'taken' })).toContainText(String(DAYS))
  await expect(rail.locator('.stat', { hasText: 'days left' })).toContainText(String(20 - DAYS))
  answerDialogs(employee, ['Plans changed'])
  await employee.locator('.req-row', { hasText: 'Winter break' }).getByRole('button', { name: 'Cancel' }).click()
  await expect(employee.locator('.req-row', { hasText: 'Cancelled: Plans changed' })).toBeVisible()
  await expect(rail.locator('.stat', { hasText: 'days left' })).toContainText('20')
  await employee.close()
})
