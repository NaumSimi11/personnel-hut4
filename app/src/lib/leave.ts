import { z } from 'zod'

/**
 * Leave (plan 036). The database owns every rule — request_leave,
 * decide_leave, cancel_leave and friends in migration 0027 re-check them —
 * this file gives the forms the same answers before a round trip and names
 * the states a request can be in.
 */

export type LeaveStatus = 'pending' | 'approved' | 'rejected' | 'cancelled'
export type CancellationState = 'none' | 'open' | 'declined'

export const NOTE_MAX = 1000
/** The statuses employment_statuses.counts_as_employed marks — request_leave accepts these. */
export const EMPLOYED_STATUSES = ['pre_start', 'active']
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/
const DAY_MS = 86_400_000

export interface LeaveRequestLike {
  person_id: string
  status: string
  start_date: string
  cancellation_requested_at: string | null
  cancellation_declined_at: string | null
}

export interface LeaveViewer {
  personId: string | null
  canApprove: boolean
}

export interface LeaveAction {
  key: 'approve' | 'reject' | 'cancel' | 'ask'
  label: string
}

/** Mirror of app.working_days: weekends, the given holidays and closures excluded. */
export function workingDaysBetween(start: string, end: string, holidays: readonly string[], closures: readonly string[]): number {
  if (!ISO_DATE.test(start) || !ISO_DATE.test(end) || start > end) return 0
  const off = new Set([...holidays, ...closures])
  const from = Date.parse(`${start}T00:00:00Z`)
  const to = Date.parse(`${end}T00:00:00Z`)
  let count = 0
  for (let t = from; t <= to; t += DAY_MS) {
    const day = new Date(t)
    const weekday = day.getUTCDay()
    const iso = day.toISOString().slice(0, 10)
    if (weekday !== 0 && weekday !== 6 && !off.has(iso)) count += 1
  }
  return count
}

export const leaveInput = z
  .object({
    leaveTypeKey: z.string().min(1, 'Choose a leave type.'),
    start: z.string().regex(ISO_DATE, 'Choose a start date.'),
    end: z.string().regex(ISO_DATE, 'Choose an end date.'),
    note: z.string().trim().max(NOTE_MAX, `Keep the note under ${NOTE_MAX} characters.`),
    documentsToFollow: z.boolean(),
  })
  .refine((input) => input.end >= input.start, { message: 'The end date cannot be before the start date.', path: ['end'] })

export type LeaveInput = z.infer<typeof leaveInput>

const STATUS_LABEL: Record<string, string> = {
  pending: 'Pending',
  approved: 'Approved',
  rejected: 'Rejected',
  cancelled: 'Cancelled',
}

export function leaveStatusLabel(status: string): string {
  return STATUS_LABEL[status] ?? status
}

/** A cancellation ask is open until a later decline answers it. */
export function cancellationState(request: Pick<LeaveRequestLike, 'status' | 'cancellation_requested_at' | 'cancellation_declined_at'>): CancellationState {
  if (request.status !== 'approved' || !request.cancellation_requested_at) return 'none'
  const declined = request.cancellation_declined_at
  if (declined && declined >= request.cancellation_requested_at) return 'declined'
  return 'open'
}

/**
 * What the viewer may do with a request, in the order the buttons show.
 * Mirrors decide_leave (never one's own), cancel_leave (owner before the
 * start, approver any time) and request_leave_cancellation (owner, after
 * the start, once per ask).
 */
export function leaveActions(request: LeaveRequestLike, viewer: LeaveViewer, today: string): LeaveAction[] {
  if (request.status === 'rejected' || request.status === 'cancelled') return []
  const own = viewer.personId === request.person_id
  const approverOfOthers = viewer.canApprove && !own
  const decide: LeaveAction[] =
    request.status === 'pending' && approverOfOthers
      ? [{ key: 'approve', label: 'Approve' }, { key: 'reject', label: 'Reject' }]
      : []
  if (approverOfOthers) return [...decide, { key: 'cancel', label: 'Cancel' }]
  if (!own) return []
  if (request.start_date > today) return [{ key: 'cancel', label: 'Cancel' }]
  if (request.status === 'approved' && cancellationState(request) !== 'open') return [{ key: 'ask', label: 'Ask to cancel' }]
  return []
}

export interface GridDay {
  iso: string
  day: number
  inMonth: boolean
  weekend: boolean
}

/** A Monday-first month grid padded to whole weeks. */
export function monthGrid(year: number, month: number): GridDay[] {
  const first = Date.UTC(year, month - 1, 1)
  const lead = (new Date(first).getUTCDay() + 6) % 7
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate()
  const total = Math.ceil((lead + daysInMonth) / 7) * 7
  return Array.from({ length: total }, (_, i) => {
    const d = new Date(first + (i - lead) * DAY_MS)
    return {
      iso: d.toISOString().slice(0, 10),
      day: d.getUTCDate(),
      inMonth: d.getUTCMonth() === month - 1,
      weekend: d.getUTCDay() === 0 || d.getUTCDay() === 6,
    }
  })
}

/** The functions already speak plainly; only a raw policy refusal needs translating. */
export function friendlyLeaveError(message: string): string {
  if (/row-level security/i.test(message)) return 'You are not allowed to change leave here.'
  return message
}
