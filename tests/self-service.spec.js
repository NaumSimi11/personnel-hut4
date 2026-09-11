// @ts-check
const { test, expect } = require('@playwright/test');

test('No-access person gets a personal page, not a dead dashboard', async ({ page }) => {
  await page.goto('/prototype/');

  await page.locator('#view-as').selectOption({ label: 'Oliver Reed · Software Engineer' });

  await expect(page.getByRole('heading', { name: 'Welcome, Oliver.' })).toBeVisible();

  const profileCard = page.locator('.card', { hasText: 'My profile' });
  await expect(profileCard).toContainText('Software Engineer');

  const accessCard = page.locator('.card', { hasText: 'My access here' });
  await expect(accessCard).toContainText('No capabilities granted in this company.');

  await expect(page.getByText('Needs a decision')).toHaveCount(0);
});

test('Hired employee sees their onboarding read-only', async ({ page }) => {
  await page.goto('/prototype/#hiring');

  const requestCard = page.locator('.card', { hasText: 'Review the hiring request' });
  await requestCard.getByRole('button', { name: 'Approve request' }).click();
  await expect(requestCard.locator('.card-head .badge')).toHaveText('Approved');

  await page.locator('.journey [data-action="hiring-step"][data-step="candidates"]').click();

  const jamieCard = page.locator('.candidate', { hasText: 'Jamie Taylor' });
  await jamieCard.getByRole('button', { name: 'Prepare offer' }).click();
  await jamieCard.getByRole('button', { name: 'Record acceptance' }).click();
  await jamieCard.getByRole('button', { name: 'Confirm hire' }).click();

  const hireForm = page.locator('#hire-form');
  await expect(hireForm).toBeVisible();
  await page.locator('#hire-department').selectOption('Operations');
  await page.getByRole('button', { name: 'Confirm hire & create plan' }).click();

  await page.locator('#view-as').selectOption({ label: 'Jamie Taylor · Operations Coordinator' });

  const onboardingCard = page.locator('.card', { hasText: 'My onboarding' });
  await expect(onboardingCard).toBeVisible();
  await expect(onboardingCard.locator('.task')).toHaveCount(5);
  await expect(onboardingCard.locator('.card-head .badge')).toHaveText('In preparation');

  await expect(onboardingCard.getByRole('button', { name: 'Mark complete' })).toHaveCount(0);
});
