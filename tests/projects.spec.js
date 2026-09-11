// @ts-check
const { test, expect } = require('@playwright/test');

test.beforeEach(async ({ page }) => {
  await page.goto('/prototype/');
});

test('Admin sees the company panel', async ({ page }) => {
  await page.getByRole('link', { name: 'Company profiles' }).click();
  await page.locator('.company-card', { hasText: 'Company A' }).getByRole('button', { name: 'Open company profile →' }).click();
  await page.locator('.tab', { hasText: 'Projects' }).click();

  const activeChannel = page.locator('.channel', { hasText: 'Website relaunch' });
  await expect(activeChannel.locator('.badge')).toHaveText('Active');

  const onHoldChannel = page.locator('.channel', { hasText: 'Internal tools cleanup' });
  await expect(onHoldChannel.locator('.badge')).toHaveText('On hold');

  await expect(page.locator('body')).toContainText('Zoho Projects (sample)');
  await expect(page.locator('body')).toContainText('read-only');
});

test('Capability gates the tab; self-service shows own assignments', async ({ page }) => {
  await page.locator('#view-as').selectOption({ label: 'Noah Bennett · Finance Specialist' });
  await page.getByRole('link', { name: 'Company profiles' }).click();
  await expect(page.locator('.tab', { hasText: 'Projects' })).toHaveCount(0);

  await page.locator('#view-as').selectOption({ label: 'Oliver Reed · Software Engineer' });
  await expect(page.locator('.card', { hasText: 'My projects' })).toContainText('Website relaunch');

  await page.locator('#view-as').selectOption({ label: 'Alex Morgan · Director' });
  await page.getByRole('link', { name: 'Company profiles' }).click();
  await expect(page.locator('.tab', { hasText: 'Projects' })).toHaveCount(1);
});
