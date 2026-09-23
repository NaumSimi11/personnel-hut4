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

// ------------------------------------------------------------ day rail
export type DayKind = 'working' | 'weekend' | 'holiday' | 'closure'

/** What a calendar day is, for the rail beside the grid. */
export function dayKind(iso: string, holidays: Record<string, string>, closures: Record<string, string>): DayKind {
  if (holidays[iso]) return 'holiday'
  if (closures[iso]) return 'closure'
  const weekday = new Date(`${iso}T00:00:00Z`).getUTCDay()
  return weekday === 0 || weekday === 6 ? 'weekend' : 'working'
}

/** "Day 3 of 5" — calendar days, the way people read a span. */
export function leaveProgress(leave: { start_date: string; end_date: string }, iso: string): { day: number; of: number } {
  const span = (from: string, to: string) => Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / DAY_MS) + 1
  return { day: span(leave.start_date, iso), of: span(leave.start_date, leave.end_date) }
}

// ------------------------------------------------------- request preview
/**
 * The balance before and after a request. `available` is what
 * requestable_leave says these dates could still draw — entitlement left
 * after pending requests plus the carry-over that fits the window — so the
 * form and request_leave never disagree. Null for types that do not
 * deduct — there is nothing to preview.
 */
export function balanceAfter(
  balance: { available: number },
  workingDays: number,
  deducts: boolean,
): { before: number; after: number; short: boolean } | null {
  if (!deducts) return null
  const before = balance.available
  const after = before - workingDays
  return { before, after, short: after < 0 }
}

export interface ClashRow {
  id: string
  person_id: string
  full_name: string
  start_date: string
  end_date: string
  status: string
  leave_type_key: string
}

/** Colleagues (given ids) away on any of the requested days — a heads-up, never a block. */
export function clashesWith(
  rows: ClashRow[],
  q: { start: string; end: string; personId: string; colleagueIds: Set<string> },
): ClashRow[] {
  return rows.filter(
    (r) => r.person_id !== q.personId && q.colleagueIds.has(r.person_id) && r.start_date <= q.end && r.end_date >= q.start,
  )
}

/** "Filip Babamov" → "Filip B." — what fits in a calendar chip. */
export function shortName(fullName: string): string {
  const parts = fullName.trim().split(/\s+/).filter(Boolean)
  if (parts.length < 2) return parts[0] ?? ''
  return `${parts[0]} ${parts[parts.length - 1]![0]!.toUpperCase()}.`
}

/** Chip colour per leave type; "away" is the redacted view. */
export const LEAVE_TYPE_TONE: Record<string, 'green' | 'amber' | 'blue' | 'grey'> = {
  annual: 'green',
  sick: 'amber',
  unpaid: 'blue',
  justified_day: 'blue',
  other: 'blue',
  away: 'grey',
}

/**
 * Where a leave stands on a given day, in working days — the unit the
 * request and the balance use (Field Notebook counted calendar days here,
 * which read as "day 11 of 15" for an 11-day leave). `of` is the server's
 * snapshot; the clicked day is counted with the same calendar rules and
 * clamped, so a holiday missing from the loaded window never overstates.
 */
export function leaveProgressWorking(
  leave: { start_date: string; end_date: string; working_days: number },
  iso: string,
  holidays: readonly string[],
  closures: readonly string[],
): { day: number; of: number; left: number } {
  const of = Number(leave.working_days)
  const day = Math.min(of, Math.max(1, workingDaysBetween(leave.start_date, iso, holidays, closures)))
  return { day, of, left: Math.max(0, of - day) }
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/** "2026-08-24" → "24 Aug" — fixed abbreviations, the same on every machine. */
export function shortDate(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`)
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`
}

// ---------------------------------------------------------- corrections
export interface CorrectionDay {
  date: string
  leave_type_key: string
}

/** The working days between two dates, in order — the rows of the correction dialog. */
export function workingDaysInRange(start: string, end: string, holidays: readonly string[], closures: readonly string[]): string[] {
  if (!ISO_DATE.test(start) || !ISO_DATE.test(end) || start > end) return []
  const off = new Set([...holidays, ...closures])
  const days: string[] = []
  for (let t = Date.parse(`${start}T00:00:00Z`); t <= Date.parse(`${end}T00:00:00Z`); t += DAY_MS) {
    const d = new Date(t)
    const weekday = d.getUTCDay()
    const iso = d.toISOString().slice(0, 10)
    if (weekday !== 0 && weekday !== 6 && !off.has(iso)) days.push(iso)
  }
  return days
}

/**
 * The line under the day pickers, as the old HR put it: how many working
 * days, and what that does to the balance against what the leave deducts
 * today. Mirrors correct_leave's deducting_before / deducting_after.
 */
export function correctionSummary(
  days: readonly CorrectionDay[],
  oldWorkingDays: number,
  oldDeducts: boolean,
  deductsByType: Record<string, boolean>,
  firstName: string,
): string {
  if (!days.length) return 'Choose at least one working day.'
  const deducting = days.filter((d) => deductsByType[d.leave_type_key]).length
  const nonDeducting = days.length - deducting
  const before = oldDeducts ? oldWorkingDays : 0
  const count = `${days.length} working ${days.length === 1 ? 'day' : 'days'}`
  const mix = nonDeducting ? ` (${nonDeducting} ${[...new Set(days.filter((d) => !deductsByType[d.leave_type_key]).map((d) => d.leave_type_key.replace('_', ' ')))].join(' / ')})` : ''
  const delta = deducting - before
  const move =
    delta === 0 ? 'the balance does not move.' : delta > 0 ? `${delta} more taken from the balance.` : `${-delta} returned to ${firstName}.`
  return `${count}${mix} — ${move}`
}

/**
 * The balances table, narrowed by what was typed (task.md: "here we ned a
 * search"). One row per person per company, so a holding with five companies
 * puts everyone employed anywhere on one screen — and the question being
 * asked of it is almost always about one person.
 *
 * The company name is matched too, because "who in Snowball has no balance
 * yet" is the other question this table gets, and the column is already
 * there to read.
 */
export function filterBalanceRows<T extends { full_name: string; company: { name: string } }>(
  rows: readonly T[],
  query: string,
): T[] {
  const needle = query.trim().toLowerCase()
  if (!needle) return [...rows]
  return rows.filter((r) => `${r.full_name} ${r.company.name}`.toLowerCase().includes(needle))
}
