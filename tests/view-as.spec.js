// @ts-check
const { test, expect } = require('@playwright/test');

test.beforeEach(async ({ page }) => {
  await page.goto('/prototype/');
});

test('Finance sees people but not hiring', async ({ page }) => {
  await page.locator('#view-as').selectOption({ label: 'Noah Bennett · Finance Specialist' });

  await expect(page.locator('#viewas-banner')).toBeVisible();
  await expect(page.locator('#viewas-banner')).toContainText('Viewing as Noah Bennett');

  await expect(page.getByRole('link', { name: 'People & access' })).toBeVisible();
  await expect(page.locator('#navigation a', { hasText: 'Hiring workspace' })).toHaveCount(0);
  await expect(page.locator('#navigation a', { hasText: 'Activity' })).toHaveCount(0);

  await expect(page.locator('#company-select option[value="all"]')).toHaveCount(0);
});

test('Director can approve but not publish', async ({ page }) => {
  await page.locator('#view-as').selectOption({ label: 'Alex Morgan · Director' });

  await expect(page.getByRole('link', { name: 'Hiring workspace' })).toBeVisible();
  await page.getByRole('link', { name: 'Hiring workspace' }).click();

  const requestCard = page.locator('.card', { hasText: 'Review the hiring request' });
  await requestCard.getByRole('button', { name: 'Approve request' }).click();
  await expect(requestCard.locator('.card-head .badge')).toHaveText('Approved');

  await page.locator('.journey [data-action="hiring-step"][data-step="job"]').click();
  const careersChannel = page.locator('.channel', { hasText: 'Company careers page' });
  await careersChannel.getByRole('button', { name: 'Publish demo listing' }).click();

  await expect(page.locator('#toast')).toContainText('Not permitted in this simulation');
  await expect(careersChannel.locator('.badge')).toHaveText('Not published');
});

test('Exit returns Admin', async ({ page }) => {
  await page.locator('#view-as').selectOption({ label: 'Alex Morgan · Director' });
  await expect(page.locator('#viewas-banner')).toBeVisible();

  await page.locator('#viewas-banner').getByRole('button', { name: 'Return to Admin' }).click();

  await expect(page.locator('#viewas-banner')).toBeHidden();
  await expect(page.locator('#company-select option[value="all"]')).toHaveCount(1);
  await expect(page.getByRole('link', { name: 'Activity' })).toBeVisible();
});
