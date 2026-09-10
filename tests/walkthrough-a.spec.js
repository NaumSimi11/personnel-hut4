// @ts-check
const { test, expect } = require('@playwright/test');

test.beforeEach(async ({ page }) => {
  await page.goto('/prototype/');
});

test('enabling payroll totals leaves salary view off and previews it, then saves and logs activity', async ({ page }) => {
  await page.getByRole('button', { name: 'Configure a director' }).click();
  const dialog = page.locator('#editor');
  await expect(dialog).toBeVisible();
  await expect(dialog.locator('#dialog-title')).toContainText('Alex');

  await dialog.locator('[data-permission="payroll.summary"]').check();
  await expect(dialog.locator('[data-permission="salary.view"]')).not.toBeChecked();
  await expect(dialog.locator('#access-preview')).toContainText('Individual salaries remain hidden.');

  await dialog.locator('[data-action="save-access"]').click();
  await expect(page.locator('#toast')).toContainText('Updated Alex Morgan');

  await page.getByRole('link', { name: 'Activity' }).click();
  await expect(page.locator('body')).toContainText('Added: View company payroll totals');
});

test('company access grants are independent per company', async ({ page }) => {
  await page.getByRole('button', { name: 'Configure a director' }).click();
  const dialog = page.locator('#editor');
  await expect(dialog).toBeVisible();

  await expect(dialog.locator('[data-group-count="Employee records"]')).toHaveText('1/4');

  await dialog.locator('#access-company').selectOption('c2');
  await expect(dialog.locator('#access-preview')).toContainText('No access to this company');

  await dialog.locator('#access-company').selectOption('c1');
  await expect(dialog.locator('[data-group-count="Employee records"]')).toHaveText('1/4');
});

test('dependency cascade: unchecking salary.view also unchecks salary.propose', async ({ page }) => {
  await page.getByRole('button', { name: 'Configure a director' }).click();
  const dialog = page.locator('#editor');
  await expect(dialog).toBeVisible();

  await dialog.locator('[data-permission="salary.propose"]').check();
  await expect(dialog.locator('[data-permission="salary.view"]')).toBeChecked();

  await dialog.locator('[data-permission="salary.view"]').uncheck();
  await expect(dialog.locator('[data-permission="salary.propose"]')).not.toBeChecked();
});
