import { expect, test, type Page } from '@playwright/test'

const EMAIL = process.env.TEST_USER_EMAIL ?? ''
const PASSWORD = process.env.TEST_USER_PASSWORD ?? ''

test.beforeAll(() => {
  test.skip(!EMAIL || !PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD in ../.env.local')
})

async function signIn(page: Page): Promise<void> {
  await page.goto('/login')
  await page.locator('#email').fill(EMAIL)
  await page.locator('#password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  // Sign-in lands on the overview; this suite works from the directory.
  await expect(page).toHaveURL(/\/overview$/)
  await page.goto('/directory')
  await expect(page.getByRole('heading', { name: 'The right access for every person.' })).toBeVisible()
}

test('unauthenticated visitors are sent to login', async ({ page }) => {
  await page.goto('/directory')
  await expect(page).toHaveURL(/\/login$/)
  await expect(page.getByRole('heading', { name: 'Sign in to your workspace.' })).toBeVisible()
})

test('wrong password shows a friendly error', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill(EMAIL)
  await page.locator('#password').fill('definitely-wrong')
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page.getByRole('alert')).toContainText('not right')
})

test('login, directory, access editor with dependency handling, sign out', async ({ page }) => {
  await signIn(page)

  // Directory shows the signed-in admin with employment context.
  const row = page.locator('tr', { hasText: 'Naum Simidjioski' })
  await expect(row).toBeVisible()

  // Open the access editor and work on the Praedium grant.
  await row.getByRole('link', { name: 'Manage access' }).click()
  await expect(page.getByRole('heading', { name: /Choose what Naum can do/ })).toBeVisible()
  await page.locator('#company').selectOption({ label: 'Praedium' })

  // Start from a clean slate so the test is repeatable.
  await page.locator('#preset').selectOption('No access')
  const save = page.getByRole('button', { name: /Save permissions|Saving…/ })
  if (await save.isEnabled()) {
    await save.click()
    await expect(page.locator('.notice')).toBeVisible()
  }

  // Dependency rule: enabling a sensitive detail view auto-enables people.view.
  const personalView = page
    .locator('.permission-check', { hasText: 'View private personal details' })
    .locator('input')
  const peopleView = page
    .locator('.permission-check', { hasText: 'View employee directory' })
    .locator('input')
  await expect(peopleView).not.toBeChecked()
  await personalView.check()
  await expect(peopleView).toBeChecked()
  await expect(page.locator('.preview-list')).toContainText('View employee directory')

  await save.click()
  await expect(page.locator('.notice')).toContainText('Permissions saved')

  // Cascade rule: removing the prerequisite removes the dependent too.
  await peopleView.uncheck()
  await expect(personalView).not.toBeChecked()

  // Clean up: back to No access, saved.
  await page.locator('#preset').selectOption('No access')
  if (await save.isEnabled()) {
    await save.click()
    await expect(page.locator('.notice')).toBeVisible()
  }

  // Sign out returns to login.
  await page.getByRole('button', { name: 'Sign out' }).click()
  await expect(page).toHaveURL(/\/login$/)
})
