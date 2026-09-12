import { z } from 'zod'

/**
 * Transfers (plan 035a): the form shape only. transfer_employment
 * (migration 0026) owns the rules — both-company capability, dates,
 * one transfer per period, what happens today versus later.
 */

export const transferInput = z.object({
  companyId: z.string().min(1, 'Choose the company to move to.'),
  effectiveDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the transfer date.'),
  jobTitle: z.string().trim().max(120),
  employmentTypeKey: z.string(),
  reason: z.string().trim().max(500, 'Keep the reason under 500 characters.'),
})

export type TransferForm = z.input<typeof transferInput>

export function friendlyTransferError(message: string): string {
  if (/employment\.edit in the target company/.test(message)) {
    return 'You need employment.edit in the target company to move someone there.'
  }
  if (/employment\.edit in the current company/.test(message)) {
    return 'You need employment.edit in this company to move someone out of it.'
  }
  return message
}
