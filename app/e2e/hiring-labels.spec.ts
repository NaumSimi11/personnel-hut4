import { expect, test } from '@playwright/test'

/**
 * Renaming the hiring vocabulary (task.md: HR is used to her own names).
 * An admin opens Hiring → Labels, renames a sub-status, sees it stick across
 * a reload, and renames it back — so the run leaves the lookup as it found
 * it. Nothing is seeded: the rows edited here ship with migration 0069.
 *
 * The empty-label refusal is asserted in the browser only; it never reaches
 * the database, so no row is touched by that half.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''

const KEY = 'interested'
const ORIGINAL = 'Interested'
const RENAMED = 'E2E Keen'

test('an admin renames a sub-status label, and it survives a reload', async ({ page }) => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto('/hiring?tab=labels')
  const panel = page.getByTestId('hiring-labels-panel')
  await expect(panel).toBeVisible()

  const row = page.getByTestId(`label-row-${KEY}`)
  const input = row.locator('input')
  await expect(input).toHaveValue(ORIGINAL)

  // Nothing to save until the text actually differs.
  await expect(page.getByTestId(`label-save-${KEY}`)).toHaveCount(0)

  // An empty label is refused in the browser, and Save stays disabled.
  await input.fill('   ')
  await expect(row).toContainText('A label cannot be empty.')
  await expect(page.getByTestId(`label-save-${KEY}`)).toBeDisabled()

  // A real rename saves, and says so.
  await input.fill(RENAMED)
  await page.getByTestId(`label-save-${KEY}`).click()
  await expect(panel).toContainText(`Renamed “${ORIGINAL}” to “${RENAMED}”`)

  // It is stored, not just on screen.
  await page.reload()
  await expect(page.getByTestId(`label-row-${KEY}`).locator('input')).toHaveValue(RENAMED)

  // Put it back, so the suite leaves the vocabulary as it found it.
  await page.getByTestId(`label-row-${KEY}`).locator('input').fill(ORIGINAL)
  await page.getByTestId(`label-save-${KEY}`).click()
  await expect(panel).toContainText(`Renamed “${RENAMED}” to “${ORIGINAL}”`)

  await page.reload()
  await expect(page.getByTestId(`label-row-${KEY}`).locator('input')).toHaveValue(ORIGINAL)
})
