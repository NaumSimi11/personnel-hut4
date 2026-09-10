// @ts-check
const { test, expect } = require('@playwright/test');

test('overview queue aggregates hiring, promotion, and onboarding items and deep-links back', async ({ page }) => {
  await page.goto('/prototype/#hiring');
  await expect(page.getByRole('heading', { name: 'One role. Every handoff connected.' })).toBeVisible();

  // 1. Approve the hiring request, move to the promotion step, and submit copy for review.
  const requestCard = page.locator('.card', { hasText: 'Review the hiring request' });
  await requestCard.getByRole('button', { name: 'Approve request' }).click();
  await expect(requestCard.locator('.card-head .badge')).toHaveText('Approved');

  await page.locator('.journey [data-action="hiring-step"][data-step="promotion"]').click();
  const promotionCard = page.locator('.card', { hasText: 'Recruitment promotion' });
  await promotionCard.getByRole('button', { name: 'Request promotion' }).click();
  await promotionCard.getByRole('button', { name: 'Submit for review' }).click();
  await expect(promotionCard.locator('.card-head .badge')).toHaveText('In review');

  // 2. The Overview queue now shows the promotion-in-review row alongside a remaining seeded hiring request.
  await page.getByRole('link', { name: 'Overview' }).click();
  const queueCard = page.locator('.card', { hasText: 'Needs a decision' });
  await expect(queueCard).toContainText('Promotion copy: Operations Coordinator');
  await expect(queueCard).toContainText('Product Designer');

  // 3. Clicking the promotion row's action deep-links to the hiring page's promotion step.
  await queueCard.getByRole('button', { name: 'Review copy' }).click();
  const promotionCardAgain = page.locator('.card', { hasText: 'Recruitment promotion' });
  await expect(promotionCardAgain).toBeVisible();
  await expect(promotionCardAgain.locator('.card-head .badge')).toHaveText('In review');
});
