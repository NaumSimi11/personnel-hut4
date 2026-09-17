import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * The handover (plan 048): the accountant is configured for the company
 * with the bank account on their list, an employee is added without one,
 * the Handover card shows the accountant red naming the bank account,
 * the private card is filled, Resend turns it green-or-queued, IT is
 * marked sent by hand, and the "Handover sent" line ticks itself once
 * every recipient is green. Seeds and cleans with the secret key.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const COMPANY_SHORT_CODE = 'SNOW'
const PERSON = 'E2E Handover Starter'
const PERSON_EMAIL = 'e2e-handover-starter@example.test'
const ACCOUNTANT = 'E2E Accountant'
const ACCOUNTANT_EMAIL = 'e2e-books@example.test'
const IT_LABEL = 'E2E IT desk'
const IT_EMAIL = 'e2e-it@example.test'

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
let ownRecipientsBefore: string[] = []

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data: people } = await db.from('people').select('id').eq('full_name', PERSON)
  for (const p of people ?? []) {
    await db.from('handover_sends').delete().eq('person_id', p.id)
    const { data: plans } = await db.from('plans').select('id').eq('person_id', p.id)
    const planIds = (plans ?? []).map((x) => x.id)
    if (planIds.length) await db.from('plan_tasks').delete().in('plan_id', planIds)
    await db.from('plans').delete().eq('person_id', p.id)
    await db.from('person_private_details').delete().eq('person_id', p.id)
    await db.from('employment_periods').delete().eq('person_id', p.id)
    await db.from('people').delete().eq('id', p.id)
  }
  if (companyId) {
    // Only what this spec added: recipients with its labels.
    await db.from('handover_recipients').delete().eq('company_id', companyId).in('label', [ACCOUNTANT, IT_LABEL])
    if (!ownRecipientsBefore.length) await db.from('handover_recipients').delete().eq('company_id', companyId)
  }
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  const db = serviceClient()
  const { data: company } = await db.from('companies').select('id, name').eq('short_code', COMPANY_SHORT_CODE).single()
  if (!company) throw new Error(`Company ${COMPANY_SHORT_CODE} not found`)
  companyId = company.id
  companyName = company.name
  const { data: own } = await db.from('handover_recipients').select('id').eq('company_id', companyId).eq('active', true)
  ownRecipientsBefore = (own ?? []).map((r) => r.id)
  await cleanup()
})

test.afterAll(cleanup)

test('accountant configured → hire without bank account is red → fill → resend → IT marked sent → line ticks', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  // Settings → Handover: the accountant (trusted, bank account + national ID) and an IT address.
  await page.goto(`/companies/${companyId}?tab=settings`)
  const panel = page.getByTestId('handover-settings')
  await expect(panel).toBeVisible()
  await panel.getByTestId('add-recipient').click()
  await panel.locator('#hr-label').fill(ACCOUNTANT)
  await panel.locator('#hr-kind').selectOption('email')
  await panel.locator('#hr-email').fill(ACCOUNTANT_EMAIL)
  // The bank account is locked until the recipient is trusted.
  await expect(panel.getByTestId('field-bank_account')).toBeDisabled()
  await panel.getByTestId('hr-trusted').check()
  await panel.getByTestId('field-bank_account').check()
  await panel.getByTestId('field-national_id').check()
  await panel.getByTestId('save-recipient').click()
  await expect(panel.getByText(new RegExp(`${ACCOUNTANT} added`))).toBeVisible()
  await expect(panel.getByTestId('handover-source')).toContainText(`${companyName}'s own list`)
  await panel.getByTestId('add-recipient').click()
  await panel.locator('#hr-label').fill(IT_LABEL)
  await panel.locator('#hr-kind').selectOption('email')
  await panel.locator('#hr-email').fill(IT_EMAIL)
  await panel.getByTestId('field-position').check()
  await panel.getByTestId('save-recipient').click()
  await expect(panel.getByText(new RegExp(`${IT_LABEL} added`))).toBeVisible()

  // A hire with no bank account.
  await page.goto('/directory')
  await page.getByTestId('add-employee').click()
  const add = page.getByTestId('add-employee-dialog')
  await add.locator('#ae-name').fill(PERSON)
  await add.locator('#ae-work-email').fill(PERSON_EMAIL)
  await add.locator('#ae-company').selectOption({ label: companyName })
  await add.locator('#ae-title').fill('Handover Analyst')
  await add.locator('#ae-start').fill(daysFromNow(7))
  await add.locator('#ae-national-id').fill('0101990450555')
  await add.getByRole('button', { name: 'Create employee' }).click()
  await add.getByTestId('open-checklist').click()

  // The Handover card: the accountant red for the bank account, IT queued.
  const card = page.getByTestId('handover-card')
  await expect(card).toBeVisible()
  const { data: person } = await db.from('people').select('id').eq('full_name', PERSON).single()
  const { data: sends } = await db.from('handover_sends').select('id, recipient_label, status, missing, fields').eq('person_id', person!.id)
  expect(sends).toHaveLength(2)
  const acc = sends!.find((s) => s.recipient_label === ACCOUNTANT)!
  const it = sends!.find((s) => s.recipient_label === IT_LABEL)!
  expect(acc.status).toBe('missing')
  expect(acc.missing).toEqual(['Bank account'])
  expect((acc.fields as Record<string, { value: string }>).national_id?.value).toBe('0101990450555')
  expect(it.status).toBe('pending')
  expect(it.fields).not.toHaveProperty('national_id')
  const accRow = card.getByTestId(`send-${acc.id}`)
  await expect(accRow.getByTestId('send-line')).toHaveText('Not sent — missing Bank account')
  const handoverLine = page.locator('.task-row', { hasText: 'Handover sent to accounting and IT' })
  await expect(handoverLine.locator('.badge', { hasText: 'open' })).toBeVisible()

  // Fill the bank account on the record, then Resend.
  await page.goto(`/people/${person!.id}`)
  await page.getByTestId('private-details-edit').click()
  await page.locator('#pd-bank').fill('NLB')
  await page.locator('#pd-account').fill('210E2E000555')
  await page.getByRole('button', { name: 'Save' }).click()
  await expect(page.getByText('Private details saved.')).toBeVisible()
  const { data: plan } = await db.from('plans').select('id').eq('person_id', person!.id).eq('kind', 'onboarding').single()
  await page.goto(`/onboarding/${plan!.id}`)
  await card.getByTestId(`send-${acc.id}`).getByTestId('resend').click()
  await expect(card.getByTestId(`send-${acc.id}`).getByTestId('send-line')).not.toContainText('missing')
  const { data: accAfter } = await db.from('handover_sends').select('status, fields').eq('id', acc.id).single()
  expect(['pending', 'sent']).toContain(accAfter!.status)
  expect((accAfter!.fields as Record<string, { value: string }>).bank_account?.value).toBe('NLB · 210E2E000555')

  // Mark both as sent by hand (mail is not configured in E2E): the line ticks itself.
  await card.getByTestId(`send-${acc.id}`).getByTestId('mark-sent').click()
  await expect(card.getByTestId(`send-${acc.id}`).getByTestId('send-line')).toContainText('Sent by hand')
  await card.getByTestId(`send-${it.id}`).getByTestId('mark-sent').click()
  await expect(card.getByTestId(`send-${it.id}`).getByTestId('send-line')).toContainText('Sent by hand')
  await expect(handoverLine.locator('.badge', { hasText: 'done' })).toBeVisible()
  const { data: line } = await db.from('plan_tasks').select('status').eq('plan_id', plan!.id).eq('task_key', 'handover').single()
  expect(line?.status).toBe('done')
})
