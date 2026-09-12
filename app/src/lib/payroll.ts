import { z } from 'zod'
import { csvCell } from '@/lib/reporting'

/**
 * Payroll preparation (plan 031): the period form, the action mirror of
 * migration 0023's functions, and the CSV handed to the accountant. Lines
 * are facts the database snapshotted — nothing here computes pay.
 */

export const periodInput = z
  .object({
    start: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the start date.'),
    end: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the end date.'),
    currency: z.string().trim().toUpperCase().regex(/^[A-Z]{3}$/, 'Currency must be a three-letter code like EUR or MKD.'),
    note: z.string().trim().max(500, 'Keep the note under 500 characters.'),
  })
  .refine((p) => p.end >= p.start, { message: 'The end must not be before the start.', path: ['end'] })

export type PeriodForm = z.input<typeof periodInput>

/** The calendar month containing `today` (an ISO date). */
export function defaultPeriod(today: string): { start: string; end: string } {
  const [y, m] = today.split('-').map(Number) as [number, number]
  const lastDay = new Date(Date.UTC(y, m, 0)).getUTCDate()
  const mm = String(m).padStart(2, '0')
  return { start: `${y}-${mm}-01`, end: `${y}-${mm}-${String(lastDay).padStart(2, '0')}` }
}

const STATUS_LABELS: Record<string, string> = {
  draft: 'Draft',
  in_review: 'In review',
  approved: 'Approved',
  exported: 'Exported',
}

export function periodStatusLabel(status: string): string {
  return STATUS_LABELS[status] ?? status
}

export type PayrollAction = { key: 'reprepare' | 'approve' | 'export' | 'reopen'; label: string }

/** Mirrors prepare / approve / mark_exported / reopen, including preparer ≠ approver. */
export function payrollActions(
  period: { status: string; prepared_by: string | null },
  personId: string | null,
  can: (cap: string) => boolean,
): PayrollAction[] {
  const out: PayrollAction[] = []
  if (period.status === 'in_review') {
    if (can('payroll.individual')) out.push({ key: 'reprepare', label: 'Prepare again' })
    if (can('payroll.approve') && personId !== null && period.prepared_by !== personId) out.push({ key: 'approve', label: 'Approve' })
  }
  if (period.status === 'approved') {
    if (can('payroll.export')) out.push({ key: 'export', label: 'Mark exported' })
    if (can('payroll.approve')) out.push({ key: 'reopen', label: 'Reopen' })
  }
  return out
}

export type PayrollLine = {
  full_name: string
  job_title: string
  amount: number
  currency: string
  pay_basis_key: string
  effective_from: string
  effective_to: string
  days_covered: number
}

export function payrollCsv(period: { period_start: string; period_end: string; currency: string }, lines: PayrollLine[]): string {
  const header = ['Person', 'Job title', 'Amount', 'Currency', 'Pay basis', 'From', 'To', 'Days covered']
  const rows = lines.map((l) => [
    l.full_name,
    l.job_title,
    Number(l.amount).toFixed(2),
    l.currency,
    l.pay_basis_key,
    l.effective_from,
    l.effective_to,
    l.days_covered,
  ])
  return [header, ...rows].map((r) => r.map(csvCell).join(',')).join('\n')
}

export function payrollFileName(period: { period_start: string; period_end: string; currency: string }, companyCode: string): string {
  return `payroll-${companyCode.toLowerCase()}-${period.period_start}-${period.period_end}-${period.currency.toLowerCase()}.csv`
}
