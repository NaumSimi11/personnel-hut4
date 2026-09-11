import { z } from 'zod'

/**
 * Compensation (plan 023): the proposal form, the working-year annualisation
 * the payroll summary uses (mirrors compensation_summary in migration 0017),
 * display formatting, and the action mirror for a pending proposal. The
 * database owns every rule — proposer ≠ approver, one open proposal, dates.
 */

export const proposalInput = z.object({
  amount: z.coerce.number().positive('Enter the amount.'),
  currency: z
    .string()
    .trim()
    .toUpperCase()
    .regex(/^[A-Z]{3}$/, 'Currency must be a three-letter code like EUR or MKD.'),
  payBasisKey: z.string().min(1, 'Choose how the amount is expressed.'),
  effectiveDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the effective date.'),
  note: z.string().trim().max(500, 'Keep the note under 500 characters.'),
})

export type ProposalForm = z.input<typeof proposalInput>

/** Standard working-year assumptions, stated in the UI next to any total. */
export const ANNUAL_FACTORS: Record<string, number> = {
  annual: 1,
  monthly: 12,
  daily: 260,
  hourly: 2080,
}

export function annualise(amount: number, payBasisKey: string): number {
  return Math.round(amount * (ANNUAL_FACTORS[payBasisKey] ?? 1) * 100) / 100
}

const wholeFormat = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 })
const fractionFormat = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

/** Whole amounts read as "66,000", anything else as "1,234.50". */
export function formatAmount(amount: number, currency: string): string {
  const text = Number.isInteger(amount) ? wholeFormat.format(amount) : fractionFormat.format(amount)
  return `${text} ${currency}`
}

type RecordLite = { status: string; effective_date: string; end_date: string | null }

/** The calendar date where the viewer is (the database compares against its own current_date). */
export function todayLocal(now = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

/** The approved record in force on `today`, or null when none covers it. */
export function currentRecord<T extends RecordLite>(records: T[], today = todayLocal()): T | null {
  return (
    records.find(
      (r) => r.status === 'approved' && r.effective_date <= today && (r.end_date === null || r.end_date >= today),
    ) ?? null
  )
}

export type CompensationAction = { to: 'approved' | 'rejected'; label: string }

/** Approve / Reject appear only for a pending proposal someone else made. */
export function compensationActions(
  record: { status: string; proposed_by: string | null },
  personId: string | null,
  can: (cap: string) => boolean,
): CompensationAction[] {
  if (record.status !== 'proposed') return []
  if (!can('salary.approve')) return []
  if (personId === null || record.proposed_by === personId) return []
  return [
    { to: 'approved', label: 'Approve' },
    { to: 'rejected', label: 'Reject' },
  ]
}

export const STATUS_LABELS: Record<string, string> = {
  proposed: 'Awaiting decision',
  approved: 'Approved',
  rejected: 'Rejected',
  superseded: 'Superseded',
}
