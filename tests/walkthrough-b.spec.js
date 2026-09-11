// @ts-check
const { test, expect } = require('@playwright/test');

test('hiring request to hired employee to onboarding readiness', async ({ page }) => {
  await page.goto('/prototype/#hiring');
  await expect(page.getByRole('heading', { name: 'One role. Every handoff connected.' })).toBeVisible();

  // 2. Approve the hiring request.
  const requestCard = page.locator('.card', { hasText: 'Review the hiring request' });
  await requestCard.getByRole('button', { name: 'Approve request' }).click();
  await expect(requestCard.locator('.card-head .badge')).toHaveText('Approved');

  // 3. Prepare the job, then publish the demo careers listing.
  await page.locator('.journey [data-action="hiring-step"][data-step="job"]').click();
  const careersChannel = page.locator('.channel', { hasText: 'Company careers page' });
  await careersChannel.getByRole('button', { name: 'Publish demo listing' }).click();
  await expect(careersChannel.locator('.badge')).toHaveText('Demo live');

  // 4. Preview careers page and submit a demo application.
  await page.getByRole('button', { name: 'Preview careers page' }).click();
  await page.locator('#applicant-name').fill('Test Applicant');
  await page.getByRole('button', { name: 'Submit demo application' }).click();
  const testApplicantCard = page.locator('.candidate', { hasText: 'Test Applicant' });
  await expect(testApplicantCard).toBeVisible();
  await expect(testApplicantCard.locator('.badge')).toHaveText('New');

  // 5. Advance Jamie Taylor through the stages to Confirm hire.
  const jamieCard = page.locator('.candidate', { hasText: 'Jamie Taylor' });
  await jamieCard.getByRole('button', { name: 'Prepare offer' }).click();
  await jamieCard.getByRole('button', { name: 'Record acceptance' }).click();
  await jamieCard.getByRole('button', { name: 'Confirm hire' }).click();
  const hireForm = page.locator('#hire-form');
  await expect(hireForm).toBeVisible();

  // 6. Cancel creates nothing; Jamie Taylor remains at Offer accepted with Confirm hire available.
  await page.getByRole('button', { name: 'Cancel' }).click();
  await expect(hireForm).toBeHidden();
  await expect(jamieCard.locator('.badge')).toHaveText('Offer accepted');
  await expect(jamieCard.getByRole('button', { name: 'Confirm hire' })).toBeVisible();

  // 7. Confirm hire again, fill in the department, and submit.
  await jamieCard.getByRole('button', { name: 'Confirm hire' }).click();
  await expect(hireForm).toBeVisible();
  await page.locator('#hire-department').selectOption('Operations');
  await page.getByRole('button', { name: 'Confirm hire & create plan' }).click();

  const handoffCard = page.locator('.channel', { hasText: 'Jamie Taylor' });
  await expect(handoffCard).toBeVisible();
  await expect(handoffCard.locator('.badge')).toHaveText('4 readiness gaps');

  // 8. Onboarding page: complete the four critical tasks, then reopen one.
  await page.getByRole('link', { name: 'Onboarding' }).click();
  const planCard = page.locator('.card[id^="plan-"]', { hasText: 'Jamie Taylor' });
  await expect(planCard).toBeVisible();
  await expect(planCard.locator('.badge')).toHaveText('Needs preparation');

  const criticalTasks = planCard.locator('.task', { hasText: 'Required before start' });
  await expect(criticalTasks).toHaveCount(4);
  for (let i = 0; i < 4; i++) {
    await criticalTasks.nth(i).getByRole('button', { name: 'Mark complete' }).click();
  }
  await expect(planCard.locator('.badge')).toHaveText('Ready for day one');

  await criticalTasks.first().getByRole('button', { name: 'Reopen' }).click();
  await expect(planCard.locator('.badge')).toHaveText('Needs preparation');

  // 9. Reload persists via localStorage; the plan and Pre-start employee remain.
  await page.reload();
  const planCardAfterReload = page.locator('.card[id^="plan-"]', { hasText: 'Jamie Taylor' });
  await expect(planCardAfterReload).toBeVisible();

  await page.getByRole('link', { name: 'People & access' }).click();
  const jamieRow = page.locator('tr', { hasText: 'Jamie Taylor' });
  await expect(jamieRow).toBeVisible();
  await expect(jamieRow.locator('.badge')).toHaveText('Pre-start');
});
