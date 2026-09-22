/**
 * Pure logic for outreach sub-statuses (plan 054): the "not responding" rule
 * as the browser mirrors it (the database decides for real, in
 * `app.not_responding` and the `recruitment_report` attention count —
 * migration 0069), the badge and timeline-line phrasing, and the lookup
 * helper for `application_sub_statuses`. Nothing here writes; `log_outreach`
 * is the only way a sub-status changes.
 */

// -------------------------------------------------------------- the lookup

export const SUB_STATUS_STAGES = ['new', 'screening'] as const
export type SubStatusStage = (typeof SUB_STATUS_STAGES)[number]

/** A row of `application_sub_statuses`, as loaded from the database. */
export type SubStatusRow = {
  key: string
  stage_key: string
  label: string
  sort_order: number
  archived_at: string | null
}

/** The trimmed shape once archived rows are filtered out — what components pass around. */
export type SubStatus = {
  key: string
  stage_key: string
  label: string
  sort_order: number
}

/** The sub-statuses of one stage, unarchived, in `sort_order`. */
export function subStatusesFor(all: SubStatusRow[], stageKey: string): SubStatus[] {
  return all
    .filter((s) => s.stage_key === stageKey && s.archived_at === null)
    .sort((a, b) => a.sort_order - b.sort_order)
    .map(({ key, stage_key, label, sort_order }) => ({ key, stage_key, label, sort_order }))
}

// -------------------------------------------------------- not responding

export const NOT_RESPONDING_DAYS = 30

const TERMINAL_STAGES = new Set(['hired', 'rejected', 'withdrawn'])
const LIVE_JOB_STATUSES = new Set(['ready', 'open', 'on_hold'])
const OPEN_OUTREACH_SUB_STATUSES = new Set(['sourced', 'contact_attempted', 'contacted'])

/** Enough of an application (+ its job) to judge D3, named to read next to the SQL by eye. */
export type OutreachRow = {
  stage_key: string
  sub_status_key: string | null
  last_activity_at: string | null
  received_at: string
  job_status: string
}

function dateOnly(iso: string): string {
  return iso.slice(0, 10)
}

function daysBetween(earlier: string, later: string): number {
  const a = Date.parse(`${earlier}T00:00:00Z`)
  const b = Date.parse(`${later}T00:00:00Z`)
  return Math.round((b - a) / 86_400_000)
}

/**
 * D3: an open application (`stage_key` not hired/rejected/withdrawn) on a
 * live job (`job_status` ready/open/on_hold) whose sub-status is sourced,
 * contact_attempted or contacted, and whose last activity — `last_activity_at`,
 * else `received_at` — is older than `NOT_RESPONDING_DAYS`. `today` is
 * `todayDb()`; both dates are compared as UTC calendar dates, not instants.
 */
export function notResponding(row: OutreachRow, today: string): boolean {
  if (TERMINAL_STAGES.has(row.stage_key)) return false
  if (!LIVE_JOB_STATUSES.has(row.job_status)) return false
  if (!row.sub_status_key || !OPEN_OUTREACH_SUB_STATUSES.has(row.sub_status_key)) return false
  const activity = dateOnly(row.last_activity_at ?? row.received_at)
  return daysBetween(activity, today) > NOT_RESPONDING_DAYS
}

/** '' or 'Not responding' — the sub-status label itself renders from the lookup (subStatusesFor). */
export function outreachBadge(row: OutreachRow, today: string): string {
  return notResponding(row, today) ? 'Not responding' : ''
}

// ------------------------------------------------------------- the timeline

/** Enough of an `outreach` application_events row to phrase the timeline line. */
export type OutreachEvent = {
  from_sub_status_key: string | null
  to_sub_status_key: string | null
  body: string | null
}

/** "Outreach: <from label or —> → <to label> · <note>", the note omitted when empty. */
export function outreachLine(event: OutreachEvent, labels: Record<string, string>): string {
  const label = (key: string | null): string => (key ? (labels[key] ?? key) : '—')
  const move = `Outreach: ${label(event.from_sub_status_key)} → ${label(event.to_sub_status_key)}`
  return event.body ? `${move} · ${event.body}` : move
}

export const OUTREACH_BLOCKED = 'Outreach is logged at New or Screening.'
