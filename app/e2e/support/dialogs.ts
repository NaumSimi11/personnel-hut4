import { expect, type Page } from '@playwright/test'

/**
 * The app asks every reason and confirmation through its own dialog
 * (AppDialogs, plan 046) — never window.prompt / window.confirm. These
 * helpers answer it the way a person would.
 */

/** Accept the open confirmation dialog. */
export async function confirmDialog(page: Page): Promise<void> {
  const dialog = page.getByTestId('reason-dialog')
  await expect(dialog).toBeVisible()
  await dialog.getByTestId('dialog-confirm').click()
  await expect(dialog).toBeHidden()
}

/** Type a reason (and a number when the dialog asks for one) and confirm. */
export async function answerReason(page: Page, reason: string, value?: number | string): Promise<void> {
  const dialog = page.getByTestId('reason-dialog')
  await expect(dialog).toBeVisible()
  if (value !== undefined) await dialog.locator('#dialog-value').fill(String(value))
  await dialog.locator('#dialog-reason').fill(reason)
  await dialog.getByTestId('dialog-confirm').click()
  await expect(dialog).toBeHidden()
}

/** Dismiss the open dialog without answering. */
export async function cancelDialog(page: Page): Promise<void> {
  const dialog = page.getByTestId('reason-dialog')
  await expect(dialog).toBeVisible()
  await dialog.getByTestId('dialog-cancel').click()
  await expect(dialog).toBeHidden()
}
