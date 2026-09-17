import { z } from 'zod'
import { csvCell } from '@/lib/reporting'

/**
 * Payroll preparation (plan 031): the period form, the action mirror of
 * migration 0023's functions, and the CSV handed to the accountant. Lines
 * are facts the database snapshotted. Plan 051 adds the bonuses and the
 * net estimate (a tax percentage and a flat deduction per company, the
 * prototype's model): the database computes it at prepare time;
 * netEstimate here only mirrors the arithmetic for the settings preview.
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
  period: { status: string; prepared_by: string | null; reopened_at?: string | null },
  personId: string | null,
  can: (cap: string) => boolean,
): PayrollAction[] {
  const out: PayrollAction[] = []
  if (period.status === 'in_review') {
    if (can('payroll.individual')) out.push({ key: 'reprepare', label: 'Prepare again' })
    // A reopened period's bonuses are pending again: it is prepared again before anyone approves.
    if (can('payroll.approve') && personId !== null && period.prepared_by !== personId && !period.reopened_at) out.push({ key: 'approve', label: 'Approve' })
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
  bonus: number
  gross: number
  tax: number
  deductions: number
  net: number
}

/** The accountant's columns as before, the estimate appended after them. */
export function payrollCsv(period: { period_start: string; period_end: string; currency: string }, lines: PayrollLine[]): string {
  const header = ['Person', 'Job title', 'Amount', 'Currency', 'Pay basis', 'From', 'To', 'Days covered', 'Bonus', 'Gross', 'Tax', 'Deductions', 'Net']
  const rows = lines.map((l) => [
    l.full_name,
    l.job_title,
    Number(l.amount).toFixed(2),
    l.currency,
    l.pay_basis_key,
    l.effective_from,
    l.effective_to,
    l.days_covered,
    Number(l.bonus).toFixed(2),
    Number(l.gross).toFixed(2),
    Number(l.tax).toFixed(2),
    Number(l.deductions).toFixed(2),
    Number(l.net).toFixed(2),
  ])
  return [header, ...rows].map((r) => r.map(csvCell).join(',')).join('\n')
}

const cents = (n: number): number => Math.round(n * 100) / 100

/** The prototype's estimate, as prepare_payroll_period computes it: tax on the gross, then the flat deduction. */
export function netEstimate(p: { amount: number; bonus: number; taxRatePercent: number; deductionsFlat: number }): { gross: number; tax: number; net: number } {
  const gross = cents(p.amount + p.bonus)
  const tax = cents((gross * p.taxRatePercent) / 100)
  return { gross, tax, net: cents(gross - tax - p.deductionsFlat) }
}

export type PeriodTotals = { amount: number; bonus: number; gross: number; tax: number; deductions: number; net: number }

export function periodTotals(lines: PayrollLine[]): PeriodTotals {
  return lines.reduce<PeriodTotals>(
    (t, l) => ({
      amount: cents(t.amount + Number(l.amount)),
      bonus: cents(t.bonus + Number(l.bonus)),
      gross: cents(t.gross + Number(l.gross)),
      tax: cents(t.tax + Number(l.tax)),
      deductions: cents(t.deductions + Number(l.deductions)),
      net: cents(t.net + Number(l.net)),
    }),
    { amount: 0, bonus: 0, gross: 0, tax: 0, deductions: 0, net: 0 },
  )
}

const numberFrom = (label: string) =>
  z
    .string()
    .trim()
    .transform((v, ctx) => {
      const n = Number(v)
      if (v === '' || !Number.isFinite(n)) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, message: label })
        return z.NEVER
      }
      return n
    })

/** A bonus for one person (add_payroll_item). */
export const bonusInput = z.object({
  person_id: z.string().min(1, 'Choose the person.'),
  amount: numberFrom('Enter the amount.').refine((n) => n > 0, 'The amount must be above zero.'),
  currency: z.string().trim().toUpperCase().regex(/^[A-Z]{3}$/, 'Currency must be a three-letter code like EUR or MKD.'),
  reason: z.string().trim().min(1, 'Say what the bonus is for.').max(200, 'Keep the reason under 200 characters.'),
  item_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the date.'),
})

export type BonusForm = z.input<typeof bonusInput>

const optionalNumber = (label: string, check: (n: number) => boolean, message: string) =>
  z
    .string()
    .trim()
    .transform((v, ctx) => {
      if (v === '') return 0
      const n = Number(v)
      if (!Number.isFinite(n)) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, message: label })
        return z.NEVER
      }
      if (!check(n)) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, message })
        return z.NEVER
      }
      return n
    })

/** Settings → Payroll (set_payroll_settings). Empty means zero. */
export const payrollSettingsInput = z.object({
  tax_rate_percent: optionalNumber('The tax rate is a number.', (n) => n >= 0 && n <= 100, 'The tax rate is a percentage between 0 and 100.'),
  deductions_flat: optionalNumber('The deduction is a number.', (n) => n >= 0, 'The deduction is not negative.'),
})

export type PayrollSettingsForm = z.input<typeof payrollSettingsInput>

export const ESTIMATE_NOTE = 'Estimate — statutory contributions are the accountant\'s.'

export function payrollFileName(period: { period_start: string; period_end: string; currency: string }, companyCode: string): string {
  return `payroll-${companyCode.toLowerCase()}-${period.period_start}-${period.period_end}-${period.currency.toLowerCase()}.csv`
}
