/**
 * The finance leave export — what is filtered, and what each row says.
 *
 * A port of Field Notebook's `shared/leaveRecordFilter.ts` and the wording of
 * its `financeReport.ts`, because the maintainer asked for *the same report*
 * on this side. It lives in `shared/` for the reason it did there: the button
 * exports what the screen is showing, and that only holds while both apply the
 * same predicate. A filter the server re-implements is a filter that will
 * eventually disagree with the list it claims to describe.
 *
 * Field names are this app's (`start_date`, `working_days`, …); the rules,
 * the column headers and the sentences are Field Notebook's.
 */

export type RecordFilter = {
  /** `YYYY-MM`, or "all". */
  month: string
  /** Company id, or "all". The screen filters by id; the name is for the file name. */
  company: string
  /** Free text over name, company and leave type. */
  query: string
}

export const EMPTY_RECORD_FILTER: RecordFilter = { month: 'all', company: 'all', query: '' }

export type FilterableRecord = {
  person_name: string
  company_id: string
  company_name: string
  leave_type: string
  start_date: string
  end_date: string
}

/** Diacritics folded, so "Ivanovski" finds "Ivanovški". */
export const foldText = (text: string): string =>
  text.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase()

/** `YYYY-MM` keys the record touches, so a filter matches leave spanning a month boundary. */
export function monthsCovered(start: string, end: string): string[] {
  const keys: string[] = []
  let year = Number(start.slice(0, 4))
  let month = Number(start.slice(5, 7))
  const endYear = Number(end.slice(0, 4))
  const endMonth = Number(end.slice(5, 7))
  while (year < endYear || (year === endYear && month <= endMonth)) {
    keys.push(`${year}-${String(month).padStart(2, '0')}`)
    month += 1
    if (month > 12) {
      month = 1
      year += 1
    }
    if (keys.length > 36) break // a request cannot span three years; guard anyway
  }
  return keys
}

export function matchesRecordFilter(record: FilterableRecord, filter: RecordFilter): boolean {
  if (filter.month !== 'all' && !monthsCovered(record.start_date, record.end_date).includes(filter.month)) return false
  if (filter.company !== 'all' && record.company_id !== filter.company) return false
  const words = foldText(filter.query).split(/\s+/).filter(Boolean)
  if (!words.length) return true
  const hay = foldText(`${record.person_name} ${record.company_name} ${record.leave_type}`)
  return words.every((word) => hay.includes(word))
}

/** Is anything actually narrowed? An untouched filter is not a filter. */
export const isRecordFilterActive = (filter: RecordFilter): boolean =>
  filter.month !== 'all' || filter.company !== 'all' || filter.query.trim() !== ''

/** Says the scope in the file name, so two exports are never mistaken for each other. */
export function describeRecordFilter(filter: RecordFilter, companyName = ''): string {
  const parts: string[] = []
  if (filter.month !== 'all') parts.push(filter.month)
  if (filter.company !== 'all' && companyName) parts.push(companyName.replace(/[^A-Za-z0-9]+/g, '-').toLowerCase())
  if (filter.query.trim()) parts.push(foldText(filter.query.trim()).replace(/[^a-z0-9]+/g, '-'))
  return parts.filter(Boolean).join('-')
}

/**
 * The year a balance is reported for. A balance has no month, so a filtered
 * month still reports the year it falls in; unfiltered, it is this year.
 * A month that is not a month falls back to today rather than to NaN.
 */
export function reportYear(filter: RecordFilter, today: string): number {
  const from = /^\d{4}-\d{2}$/.test(filter.month) ? filter.month : today
  const year = Number(from.slice(0, 4))
  return Number.isInteger(year) ? year : Number(today.slice(0, 4))
}

/** person + company: the key a summary row is identified by. */
export const balanceKey = (personId: string, companyId: string): string => `${personId}|${companyId}`

/**
 * Dated, so two exports never overwrite each other in a downloads folder — and
 * scoped, so a December-only export cannot later be mistaken for the full year.
 */
export const leaveReportFilename = (today: string, scope = ''): string =>
  `leave-finance-export-${scope ? `${scope}-` : ''}${today}.xlsx`

// ------------------------------------------------------------------ rows

export const RECORD_COLUMNS = [
  'Request ID',
  'Employee',
  'Company',
  'Country',
  'Start date',
  'End date',
  'Leave type',
  'Working days',
  'Status',
  'Annual balance effect',
] as const

export const SUMMARY_COLUMNS = [
  'Employee',
  'Company',
  'Country',
  'Status',
  'Annual allowance',
  'Approved annual leave',
  'Annual leave remaining',
  'Carry-over remaining',
  'Current-year entitlement remaining',
] as const

export type ReportRequest = FilterableRecord & {
  /** Field Notebook's number where the row was imported from it, else this app's id. */
  reference: string
  /** Who it belongs to. With `company_id` it keys the summary — a name cannot,
   *  since two people may share one and one person may work in two companies. */
  person_id: string
  working_days: number
  status: string
  /** The request's own snapshot of whether it charges the annual balance. */
  deducts_balance: boolean
  country_code: string | null
}

export type ReportPerson = {
  person_name: string
  company_name: string
  country_code: string | null
  /** The employment status as stored: `active`, `former`, … */
  employment_status: string
  entitlement: number
  approved_days: number
  remaining: number
  carry_over_remaining: number
  /** False when no balance row exists for that year — see NOT_APPLICABLE. */
  has_balance: boolean
}

/** The policy ledger only exists once a year has a balance row. */
export const NOT_APPLICABLE = 'Not applicable'

/** The three countries the holding works in; anything else prints its code. */
const COUNTRY_NAMES: Record<string, string> = { MK: 'North Macedonia', RS: 'Serbia', MT: 'Malta' }

export const countryName = (code: string | null): string => (code ? (COUNTRY_NAMES[code] ?? code) : '—')

/**
 * What this request does to the annual balance, in words.
 *
 * Reads the request's OWN snapshot of whether it deducts, never the leave
 * type's current flag — if HR later makes a type deduct, past requests of that
 * type must not retroactively read as charges.
 */
export function balanceEffect(request: Pick<ReportRequest, 'deducts_balance' | 'status' | 'working_days'>): string {
  const days = request.working_days
  const word = days === 1 ? 'day' : 'days'
  if (!request.deducts_balance) return 'No annual leave deduction'
  if (request.status === 'approved') return `Deducts ${days} annual leave ${word}`
  if (request.status === 'cancelled') return `Cancelled — ${days} ${word} returned`
  return 'No deduction until approved'
}

/** Active or not, in this app's vocabulary (Field Notebook says "Archived"). */
export const employmentLabel = (status: string): string => (status === 'active' ? 'Active' : 'Former')

/** One row of the "Leave records" sheet, in column order. */
export function recordRow(request: ReportRequest): (string | number)[] {
  return [
    request.reference,
    // The dash is a rendering, not a value: filtering must never match it, so
    // the missing name stays empty until the sheet is written.
    request.person_name || '—',
    request.company_name || '—',
    countryName(request.country_code),
    request.start_date,
    request.end_date,
    request.leave_type,
    request.working_days,
    request.status,
    balanceEffect(request),
  ]
}

/** One row of the "Balance summary" sheet, in column order. */
export function summaryRow(person: ReportPerson): (string | number)[] {
  return [
    person.person_name || '—',
    person.company_name || '—',
    countryName(person.country_code),
    employmentLabel(person.employment_status),
    person.entitlement,
    person.approved_days,
    person.remaining + person.carry_over_remaining,
    // Saying so beats printing a 0 that finance would read as "nothing left".
    person.has_balance ? person.carry_over_remaining : NOT_APPLICABLE,
    person.has_balance ? person.remaining : NOT_APPLICABLE,
  ]
}

/** Oldest first, then by name — the order Field Notebook's export uses. */
export function sortRequests<T extends { start_date: string; person_name: string }>(rows: ReadonlyArray<T>): T[] {
  return [...rows].sort((a, b) => a.start_date.localeCompare(b.start_date) || a.person_name.localeCompare(b.person_name))
}

/** By company, then by name. */
export function sortPeople<T extends { company_name: string; person_name: string }>(rows: ReadonlyArray<T>): T[] {
  return [...rows].sort((a, b) => a.company_name.localeCompare(b.company_name) || a.person_name.localeCompare(b.person_name))
}
