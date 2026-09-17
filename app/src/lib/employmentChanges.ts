import { z } from 'zod'
import { departureState } from '@/lib/departure'
import { todayDb } from '@/lib/compensation'

/**
 * Employment changes (plan 022): the form that schedules a dated change to
 * title / department / location / manager / employment type, the diff that
 * becomes the change record, and the directory's view of "current" and its
 * filters. The database (schedule_employment_change, migration 0016) owns
 * the rules — effective date, company scoping, circular reporting.
 */

export const changeInput = z.object({
  effectiveDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the effective date.'),
  jobTitle: z.string().trim().min(2, 'Enter the job title.').max(120),
  departmentId: z.string(),
  locationId: z.string(),
  managerId: z.string(),
  employmentTypeKey: z.string(),
  reason: z.string().trim().max(500, 'Keep the reason under 500 characters.'),
})

export type ChangeForm = z.input<typeof changeInput>

export type PeriodFields = {
  job_title: string
  department_id: string | null
  location_id: string | null
  manager_id: string | null
  employment_type_key: string | null
}

/** Only what differs; an empty string means "clear this field". */
export function diffChanges(period: PeriodFields, form: ChangeForm): Record<string, string> {
  const out: Record<string, string> = {}
  const title = form.jobTitle.trim()
  if (title && title !== period.job_title) out.job_title = title
  if (form.departmentId !== (period.department_id ?? '')) out.department_id = form.departmentId
  if (form.locationId !== (period.location_id ?? '')) out.location_id = form.locationId
  if (form.managerId !== (period.manager_id ?? '')) out.manager_id = form.managerId
  if (form.employmentTypeKey && form.employmentTypeKey !== (period.employment_type_key ?? '')) {
    out.employment_type_key = form.employmentTypeKey
  }
  return out
}

export type Lookups = {
  departments: Record<string, string>
  locations: Record<string, string>
  people: Record<string, string>
  employmentTypes: Record<string, string>
}

const FIELD_LABELS: Record<string, string> = {
  job_title: 'Job title',
  department_id: 'Department',
  location_id: 'Location',
  manager_id: 'Manager',
  employment_type_key: 'Employment type',
}

export function describeChanges(changes: Record<string, unknown>, lookups: Lookups): string {
  return Object.entries(changes)
    .map(([field, value]) => {
      const raw = typeof value === 'string' ? value : ''
      let label = raw
      if (field === 'department_id') label = lookups.departments[raw] ?? raw
      if (field === 'location_id') label = lookups.locations[raw] ?? raw
      if (field === 'manager_id') label = lookups.people[raw] ?? raw
      if (field === 'employment_type_key') label = lookups.employmentTypes[raw] ?? raw
      return `${FIELD_LABELS[field] ?? field} → ${label || 'none'}`
    })
    .join(' · ')
}

// ------------------------------------------------------------- directory

type PeriodLite = { status: string; start_date: string; end_date: string | null }

/**
 * The period that describes someone today: the non-former one that has
 * already started (latest first), else the soonest upcoming one, else the
 * latest former one. A future transfer never hides the current job.
 */
export function currentPeriod<T extends PeriodLite>(periods: T[], today = todayDb()): T | null {
  const live = periods.filter((p) => p.status !== 'former')
  const started = live.filter((p) => p.start_date <= today).sort((a, b) => b.start_date.localeCompare(a.start_date))
  if (started[0]) return started[0]
  const upcoming = live.filter((p) => p.start_date > today).sort((a, b) => a.start_date.localeCompare(b.start_date))
  if (upcoming[0]) return upcoming[0]
  const all = [...periods].sort((a, b) => b.start_date.localeCompare(a.start_date))
  return all[0] ?? null
}

export const DIRECTORY_FILTERS = [
  { key: 'active', label: 'Active' },
  { key: 'all', label: 'Everyone' },
  { key: 'starting', label: 'Starting soon' },
  { key: 'departing', label: 'Departing' },
  { key: 'former', label: 'Former' },
  { key: 'none', label: 'No employment' },
] as const

export type DirectoryFilter = (typeof DIRECTORY_FILTERS)[number]['key']

export function matchesFilter(filter: DirectoryFilter, period: PeriodLite | null): boolean {
  if (filter === 'all') return true
  if (!period) return filter === 'none'
  const state = departureState(period)
  switch (filter) {
    case 'active':
      return period.status === 'active' && state === 'employed'
    case 'starting':
      return period.status === 'pre_start'
    case 'departing':
      return state === 'departing'
    case 'former':
      return state === 'former'
    default:
      return false
  }
}
