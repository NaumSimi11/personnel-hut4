import { formatAmount } from '@/lib/compensation'
import { notResponding, type OutreachRow } from '@/lib/outreach'

/**
 * Dashboard facts (plan 044): pure shaping of what the page reads — the
 * applicant pipeline and recruitment snapshot from applications and jobs
 * (RLS decides what the viewer sees), who is away today from leave, and
 * labels for the celebrate block. The team facts themselves (birthdays,
 * anniversaries, newcomers, kudos, payroll) come shaped from
 * `dashboard_snapshot`.
 */

export type ApplicationLite = {
  id: string
  job_id: string
  stage_key: string
  /** Plan 054; with the candidate's last activity and the job status it feeds notRespondingCount. */
  sub_status_key?: string | null
  received_at: string
  candidate: { full_name: string; last_activity_at?: string | null } | null
  job: { title: string; status?: string; company: { name: string } | null } | null
}

export type JobLite = {
  id: string
  title: string
  status: string
  company: { name: string } | null
  request: { headcount: number } | null
}

export type LeaveLite = {
  id: string
  status: string
  start_date: string
  end_date: string
  leave_type_key: string
  person: { full_name: string } | null
}

export type PayrollFact = {
  company_name: string
  period_start: string
  period_end: string
  currency: string
  total: number
  people: number
  status: string
}

/** The stages of the prototype's pipeline bars, in order; withdrawn stays out of the chart. */
export const PIPELINE_STAGES: ReadonlyArray<{ key: string; label: string; tone: 'blue' | 'green' | 'red' }> = [
  { key: 'new', label: 'Applied', tone: 'blue' },
  { key: 'screening', label: 'Screening', tone: 'blue' },
  { key: 'interview', label: 'Interview', tone: 'blue' },
  { key: 'offer', label: 'Offer', tone: 'blue' },
  { key: 'hired', label: 'Hired', tone: 'green' },
  { key: 'rejected', label: 'Rejected', tone: 'red' },
]

const CLOSED_STAGES = new Set(['hired', 'rejected', 'withdrawn'])

export function stageLabel(key: string): string {
  return PIPELINE_STAGES.find((s) => s.key === key)?.label ?? (key === 'withdrawn' ? 'Withdrawn' : key)
}

export type Celebrant = { id: string; full_name: string; job_title: string | null; company_name: string }
export type KudosRow = {
  id: string
  message: string
  created_at: string
  from_person_id: string
  to_person_id: string
  from_name: string
  to_name: string
  mine: boolean
  value_id: string | null
  value_name: string | null
}

/** What `dashboard_snapshot` returns: the team facts, already scoped to the viewer's companies. */
export type DashboardSnapshot = {
  headcount: number
  active: number
  starting: number
  colleagues: Array<{ id: string; full_name: string; company_name: string }>
  birthdays: Array<Celebrant & { on_day: string; in_days: number }>
  anniversaries: Array<Celebrant & { years: number; in_days: number }>
  newcomers: Array<Celebrant & { start_date: string }>
  kudos: KudosRow[]
  top_kudos: { full_name: string; count: number } | null
  biggest_team: { name: string; people: number } | null
  anniversaries_this_year: number
  payroll: PayrollFact[]
}

export const EMPTY_SNAPSHOT: DashboardSnapshot = {
  headcount: 0,
  active: 0,
  starting: 0,
  colleagues: [],
  birthdays: [],
  anniversaries: [],
  newcomers: [],
  kudos: [],
  top_kudos: null,
  biggest_team: null,
  anniversaries_this_year: 0,
  payroll: [],
}

/**
 * What the viewer holds, anywhere in the holding — the same hint the rest of
 * the app uses (`auth.canAnywhere`). The database limits the data; this only
 * decides whether a panel is worth drawing at all.
 */
export type Viewer = { canAnywhere: (capability: string) => boolean }

export type StatTile = { key: string; label: string; value: string | number; sub?: string; tone?: 'hot' | 'gold' }

/**
 * The headline tiles, each behind the capability that governs its data:
 * the team behind people.view, who is away behind leave.view / leave.approve,
 * applicants behind candidates.view, requests behind jobs.approve. The
 * payroll tile appears only when the snapshot actually carried a period —
 * `payroll.summary` is checked in the database, not here.
 */
export function statTiles(input: {
  snapshot: DashboardSnapshot
  away: ReadonlyArray<AwayRow>
  applications: ReadonlyArray<ApplicationLite>
  requestsToDecide: number
  viewer: Viewer
}): StatTile[] {
  const { snapshot, away, applications, requestsToDecide, viewer } = input
  const tiles: StatTile[] = []
  if (viewer.canAnywhere('people.view')) {
    tiles.push({
      key: 'active',
      label: 'Active employees',
      value: snapshot.active,
      sub: snapshot.starting ? `${snapshot.starting} starting soon` : undefined,
    })
  }
  if (viewer.canAnywhere('leave.view') || viewer.canAnywhere('leave.approve')) {
    tiles.push({ key: 'away', label: 'Away today', value: away.length, tone: away.length ? 'hot' : undefined })
  }
  if (viewer.canAnywhere('candidates.view')) {
    tiles.push({ key: 'applicants', label: 'Applicants in progress', value: applicantsInProgress(applications) })
  }
  if (viewer.canAnywhere('jobs.approve')) {
    tiles.push({ key: 'requests', label: 'Hiring requests to decide', value: requestsToDecide })
  }
  const pay = snapshot.payroll[0]
  if (pay) {
    const { value, sub } = payrollLabel(pay)
    const more = snapshot.payroll.length - 1
    tiles.push({ key: 'payroll', label: 'Last payroll', value, sub: more ? `${sub} · +${more} more` : sub, tone: 'gold' })
  }
  return tiles
}

/** Which blocks of the Home the viewer may see anything in. */
export function dashboardSections(viewer: Viewer): {
  team: boolean
  pipeline: boolean
  openings: boolean
  recruitment: boolean
  away: boolean
} {
  const pipeline = viewer.canAnywhere('candidates.view')
  const openings = viewer.canAnywhere('jobs.view')
  return {
    team: viewer.canAnywhere('people.view'),
    pipeline,
    openings,
    recruitment: pipeline || openings,
    away: viewer.canAnywhere('leave.view') || viewer.canAnywhere('leave.approve'),
  }
}

export function pipelineCounts(apps: ReadonlyArray<ApplicationLite>): Array<{ key: string; label: string; tone: string; count: number }> {
  return PIPELINE_STAGES.map((s) => ({ ...s, count: apps.filter((a) => a.stage_key === s.key).length }))
}

export function applicantsInProgress(apps: ReadonlyArray<ApplicationLite>): number {
  return apps.filter((a) => !CLOSED_STAGES.has(a.stage_key)).length
}

export type OpenPosition = { id: string; title: string; company: string; headcount: number; applicants: number }

const HIRING_JOB_STATUSES = new Set(['ready', 'open'])

/** Roles being hired (ready or open) with their live applicant count; headcount comes from the hiring request (1 when the job was prepared without one). */
export function openPositions(jobs: ReadonlyArray<JobLite>, apps: ReadonlyArray<ApplicationLite>): OpenPosition[] {
  return jobs
    .filter((j) => HIRING_JOB_STATUSES.has(j.status))
    .map((j) => ({
      id: j.id,
      title: j.title,
      company: j.company?.name ?? '—',
      headcount: j.request?.headcount ?? 1,
      applicants: apps.filter((a) => a.job_id === j.id && !CLOSED_STAGES.has(a.stage_key)).length,
    }))
}

export type RecentApplicant = { id: string; name: string; position: string; company: string; stage: string; received_at: string }

export function recentApplicants(apps: ReadonlyArray<ApplicationLite>, limit = 5): RecentApplicant[] {
  return [...apps]
    .sort((a, b) => b.received_at.localeCompare(a.received_at))
    .slice(0, limit)
    .map((a) => ({
      id: a.id,
      name: a.candidate?.full_name ?? 'Candidate',
      position: a.job?.title ?? '—',
      company: a.job?.company?.name ?? '—',
      stage: a.stage_key,
      received_at: a.received_at,
    }))
}

export type AwayRow = { id: string; name: string; type: string; until: string; backOn: boolean }

/** Approved leave covering today; `backOn` when today is the last day. */
export function awayToday(rows: ReadonlyArray<LeaveLite>, today: string): AwayRow[] {
  return rows
    .filter((r) => r.status === 'approved' && r.start_date <= today && r.end_date >= today)
    .sort((a, b) => (a.person?.full_name ?? '').localeCompare(b.person?.full_name ?? ''))
    .map((r) => ({ id: r.id, name: r.person?.full_name ?? '—', type: r.leave_type_key, until: r.end_date, backOn: r.end_date === today }))
}

export function inDaysLabel(days: number): string {
  if (days <= 0) return 'Today'
  if (days === 1) return 'Tomorrow'
  return `In ${days} days`
}

const SHOUTOUT_LINES = [
  'is quietly keeping everything running smoothly.',
  'brought great energy to the team this week.',
  'is someone you can always count on.',
  'deserves a coffee on the house today.',
  'has been crushing it lately — noticed and appreciated.',
]

function hashCode(text: string): number {
  return Array.from(text).reduce((h, ch) => (Math.imul(31, h) + ch.charCodeAt(0)) | 0, 0)
}

/** The same person always gets the same line, so a re-render never changes the shoutout under the reader. */
export function shoutoutLine(personId: string): string {
  return SHOUTOUT_LINES[Math.abs(hashCode(personId)) % SHOUTOUT_LINES.length]!
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

function longDate(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`)
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`
}

export function payrollLabel(p: PayrollFact): { value: string; sub: string } {
  return {
    value: formatAmount(Number(p.total), p.currency),
    sub: `${p.company_name} · to ${longDate(p.period_end)} · ${p.people} ${p.people === 1 ? 'person' : 'people'}`,
  }
}

/**
 * What D3 (plan 054) needs from a list row. The candidate's last_activity_at
 * stands in for the application's newest event: 0067 bumps it on every
 * application event (and on files and assignment edits too), so it is never
 * earlier than that event — a list judged this way may under-flag, never
 * over-flag. The report (app.not_responding, 0069) is authoritative.
 */
export type OutreachLite = {
  stage_key: string
  sub_status_key?: string | null
  received_at: string
  candidate: { last_activity_at?: string | null } | null
  job: { status?: string } | null
}

export function outreachRowOf(a: OutreachLite): OutreachRow {
  return {
    stage_key: a.stage_key,
    sub_status_key: a.sub_status_key ?? null,
    last_activity_at: a.candidate?.last_activity_at ?? null,
    received_at: a.received_at,
    job_status: a.job?.status ?? '',
  }
}

/** Home's pipeline line: how many of the loaded applications are not responding today. */
export function notRespondingCount(apps: ReadonlyArray<OutreachLite>, today: string): number {
  return apps.filter((a) => notResponding(outreachRowOf(a), today)).length
}
