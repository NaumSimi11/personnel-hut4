import { expect, test, type Page } from '@playwright/test'

/**
 * Export follows the Applicants filters (20 Nov). Read-only: it filters,
 * exports, and reads what the browser sent and saved; nothing is written.
 *
 * What the file holds for each filter is proved row by row in
 * server/src/hiringExportFilter.test.ts (every combination, against the
 * list's own rules). This checks the page's half: the filters on screen are
 * the ones the button sends, separately and combined, and "Export everyone"
 * sends none.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''

type Sent = { today: string; scope: string; filter?: { stage: string; status: string; companyId: string; search: string } }

async function exportAndRead(page: Page, testId: string): Promise<{ sent: Sent; filename: string }> {
  const [request, download] = await Promise.all([
    page.waitForRequest((r) => r.url().endsWith('/api/reports/hiring-export') && r.method() === 'POST'),
    page.waitForEvent('download'),
    page.getByTestId(testId).click(),
  ])
  return { sent: JSON.parse(request.postData() ?? '{}') as Sent, filename: download.suggestedFilename() }
}

test('the export sends the filters on screen, alone and together', async ({ page }) => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)
  await page.goto('/hiring?tab=applicants')
  await expect(page.getByTestId('applicants-export')).toBeVisible()

  // Nothing touched: the list opens on In progress, and so does the file.
  let r = await exportAndRead(page, 'applicants-export')
  expect(r.sent.scope).toBe('filtered')
  expect(r.sent.filter).toEqual({ stage: 'live', status: '', companyId: '', search: '' })
  expect(r.filename).toMatch(/^peopleos-candidates-filtered-\d{4}-\d{2}-\d{2}\.xlsx$/)

  // One filter at a time.
  await page.getByLabel('Stage').selectOption('interview')
  r = await exportAndRead(page, 'applicants-export')
  expect(r.sent.filter).toEqual({ stage: 'interview', status: '', companyId: '', search: '' })

  const statusFilter = page.getByTestId('applicants-status-filter')
  const firstStatus = await statusFilter.locator('option').nth(1).getAttribute('value')
  expect(firstStatus).toBeTruthy()
  await statusFilter.selectOption(firstStatus ?? '')
  r = await exportAndRead(page, 'applicants-export')
  expect(r.sent.filter).toMatchObject({ stage: 'interview', status: firstStatus })

  // All of them together, with a name typed in.
  await page.getByLabel('Search applicants').fill('ana')
  await page.waitForTimeout(400) // the list's own search delay
  r = await exportAndRead(page, 'applicants-export')
  expect(r.sent.filter).toMatchObject({ stage: 'interview', status: firstStatus, search: 'ana' })

  // Back to All stages and no status: only the name is left.
  await page.getByLabel('Stage').selectOption('all')
  await statusFilter.selectOption('')
  r = await exportAndRead(page, 'applicants-export')
  expect(r.sent.filter).toEqual({ stage: 'all', status: '', companyId: '', search: 'ana' })

  // Export everyone ignores whatever is set.
  r = await exportAndRead(page, 'applicants-export-everyone')
  expect(r.sent.scope).toBe('everyone')
  expect(r.sent.filter).toBeUndefined()
  expect(r.filename).toMatch(/^peopleos-candidates-\d{4}-\d{2}-\d{2}\.xlsx$/)
})
