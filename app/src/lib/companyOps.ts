/**
 * Company operations (plan 024): who is about to start or leave, and the
 * informational approval routing read from workflow_owners. The database
 * still decides who may approve; these helpers only shape what is shown.
 */

type PeriodLite = {
  status: string
  start_date: string
  end_date: string | null
  last_working_date: string | null
}

export type Upcoming<T> = { starters: T[]; departures: T[] }

/**
 * Pre-start employment soonest first — including overdue starts, since nothing
 * flips pre_start to active by itself; active employment ending on or after
 * today, soonest first.
 */
export function upcoming<T extends PeriodLite>(periods: T[], today: string): Upcoming<T> {
  const starters = periods
    .filter((p) => p.status === 'pre_start')
    .sort((a, b) => a.start_date.localeCompare(b.start_date))
  const departures = periods
    .filter((p) => p.status === 'active' && p.end_date !== null && p.end_date >= today)
    .sort((a, b) => (a.end_date as string).localeCompare(b.end_date as string))
  return { starters, departures }
}

export const NO_APPROVER = 'Awaiting approval · no approver configured'

export function awaitingLabel(owner: { person: { full_name: string } | null } | undefined): string {
  return owner?.person ? `Awaiting ${owner.person.full_name}` : NO_APPROVER
}
