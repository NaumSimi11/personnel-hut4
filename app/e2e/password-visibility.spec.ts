import { expect, test } from '@playwright/test'

/**
 * Every password field has a show / hide toggle (one component, used on
 * sign-in and on set-password): what you typed can be checked before you
 * submit, and hidden again.
 */
test('the sign-in password can be shown and hidden', async ({ page }) => {
  await page.goto('/login')
  const field = page.locator('#password')
  const toggle = page.getByTestId('toggle-password')

  await field.fill('Temp0rary!Pass')
  await expect(field).toHaveAttribute('type', 'password')
  await expect(toggle).toHaveAttribute('aria-label', 'Show password')

  await toggle.click()
  await expect(field).toHaveAttribute('type', 'text')
  await expect(field).toHaveValue('Temp0rary!Pass')
  await expect(toggle).toHaveAttribute('aria-label', 'Hide password')
  await expect(toggle).toHaveAttribute('aria-pressed', 'true')

  await toggle.click()
  await expect(field).toHaveAttribute('type', 'password')
  // The label still targets the field, so clicking it focuses the input.
  await page.getByText('Password', { exact: true }).click()
  await expect(field).toBeFocused()
})
