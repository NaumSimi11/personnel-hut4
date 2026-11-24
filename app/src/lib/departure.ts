import { z } from 'zod'

/**
 * Departures (plan 016). The database owns the workflow — schedule_departure
 * and complete_departure in migration 0010 — and re-validates every rule
 * below; this file gives the form the same answers before a round trip and
 * names the three states an employment period can be in.
 */

export type DepartureState = 'employed' | 'departing' | 'former'

export const REASON_MAX = 500

/** Days after the start date that Did not start stays on offer (mark_did_not_start, migration 0128). */
export const DID_NOT_START_GRACE_DAYS = 7

/**
 * Did not start (audit B4): before the first day, on it, and for a week
 * after, since a no-show is often noticed late. The database checks it again.
 */
export function canMarkDidNotStart(period: { status: string; start_date: string }, today: string): boolean {
  if (period.status === 'pre_start') return true
  if (period.status !== 'active') return false
  const cutoff = new Date(`${today}T00:00:00Z`)
  cutoff.setUTCDate(cutoff.getUTCDate() - DID_NOT_START_GRACE_DAYS)
  return period.start_date >= cutoff.toISOString().slice(0, 10)
}
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

/** A period with an end date is departing until the explicit act of becoming former. */
export function departureState(period: { status: string; end_date: string | null }): DepartureState {
  if (period.status === 'former') return 'former'
  if (period.end_date) return 'departing'
  return 'employed'
}

/** Schema for the schedule-departure form, bound to the period's start date. */
export function departureInput(startDate: string) {
  return z
    .object({
      endDate: z.string().regex(ISO_DATE, 'Choose an employment end date.'),
      lastWorkingDate: z.union([z.literal(''), z.string().regex(ISO_DATE, 'Choose a valid last working date.')]),
      reason: z.string().trim().max(REASON_MAX, `Keep the reason under ${REASON_MAX} characters.`),
    })
    .transform((input) => ({
      ...input,
      lastWorkingDate: input.lastWorkingDate || input.endDate,
    }))
    .refine((input) => input.endDate >= startDate, {
      message: 'The end date cannot be before the start date.',
      path: ['endDate'],
    })
    .refine((input) => input.lastWorkingDate <= input.endDate, {
      message: 'The last working date cannot be after the employment end date.',
      path: ['lastWorkingDate'],
    })
}

export type DepartureInput = z.infer<ReturnType<typeof departureInput>>

export function friendlyDepartureError(message: string): string {
  if (/requires departure\.start/.test(message)) {
    return 'You need the "Start offboarding" capability in this company.'
  }
  return message
}
