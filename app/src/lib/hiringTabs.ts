import { outreachRowOf, stageLabel } from '@/lib/dashboard'
import { todayDb } from '@/lib/compensation'
import { shortDate } from '@/lib/leave'
import { notResponding } from '@/lib/outreach'

/**
 * The Hiring page's list tabs (plan 044): Job openings and Applicants, flat
 * across every job the viewer may see — what the prototype's Recruitment
 * had and our per-job workspace lacked. Pure shaping; RLS decides the rows.
 */

export const JOB_STATUS_LABEL: Record<string, string> = {
  draft: 'Draft',
  ready: 'Ready',
  open: 'Open',
  on_hold: 'On hold',
  filled: 'Filled',
  closed: 'Closed',
}
const LIVE_JOB_STATUSES = new Set(['ready', 'open', 'on_hold'])
const CLOSED_STAGES = new Set(['hired', 'rejected', 'withdrawn'])

export type OpeningJobLite = {
  id: string
  title: string
  status: string
  company_id: string
  company: { name: string } | null
  request: { headcount: number; manager: { full_name: string } | null } | null
}
export type OpeningApplicationLite = { id: string; job_id: string; stage_key: string }

export type JobOpeningRow = {
  id: string
  title: string
  company: string
  statusLabel: string
  statusTone: 'green' | 'amber' | 'blue' | ''
  headcount: number
  inPlay: number
  hired: number
  manager: string | null
}

function jobStatusTone(status: string): JobOpeningRow['statusTone'] {
  if (status === 'open') return 'green'
  if (status === 'on_hold') return 'amber'
  if (status === 'ready') return 'blue'
  return ''
}

export function openingRows(
  jobs: ReadonlyArray<OpeningJobLite>,
  apps: ReadonlyArray<OpeningApplicationLite>,
  filter: { companyId: string; status: string },
): JobOpeningRow[] {
  return jobs
    .filter((j) => !filter.companyId || j.company_id === filter.companyId)
    .filter((j) => (filter.status === 'all' ? true : filter.status === 'live' ? LIVE_JOB_STATUSES.has(j.status) : j.status === filter.status))
    .map((j) => {
      const own = apps.filter((a) => a.job_id === j.id)
      return {
        id: j.id,
        title: j.title,
        company: j.company?.name ?? '—',
        statusLabel: JOB_STATUS_LABEL[j.status] ?? j.status,
        statusTone: jobStatusTone(j.status),
        headcount: j.request?.headcount ?? 1,
        inPlay: own.filter((a) => !CLOSED_STAGES.has(a.stage_key)).length,
        hired: own.filter((a) => a.stage_key === 'hired').length,
        manager: j.request?.manager?.full_name ?? null,
      }
    })
}

export type ApplicantLite = {
  id: string
  company_id: string
  stage_key: string
  /** Plan 054; the candidate's last activity and the job status judge "not responding" (see outreachRowOf). */
  sub_status_key?: string | null
  received_at: string
  next_action: string | null
  next_action_due: string | null
  candidate: { full_name: string; email: string | null; last_activity_at?: string | null } | null
  job: { id: string; title: string; status?: string; company: { name: string } | null } | null
  owner: { full_name: string } | null
}

export type ApplicantRow = {
  id: string
  jobId: string | null
  name: string
  email: string | null
  position: string
  company: string
  stage: string
  stageLabel: string
  subStatusKey: string | null
  notResponding: boolean
  received: string
  owner: string | null
  nextAction: string | null
}

/** The stage filter's pseudo-value (plan 054): open outreach with no activity in 30 days, judged over the loaded rows. */
export const NOT_RESPONDING_FILTER = 'not_responding'

function stageMatches(a: ApplicantLite, stage: string, today: string): boolean {
  if (stage === 'all') return true
  if (stage === 'live') return !CLOSED_STAGES.has(a.stage_key)
  if (stage === NOT_RESPONDING_FILTER) return notResponding(outreachRowOf(a), today)
  return a.stage_key === stage
}

export function applicantRows(
  apps: ReadonlyArray<ApplicantLite>,
  filter: { companyId: string; stage: string; search: string; today?: string },
): ApplicantRow[] {
  const needle = filter.search.trim().toLowerCase()
  const today = filter.today ?? todayDb()
  return [...apps]
    .filter((a) => !filter.companyId || a.company_id === filter.companyId)
    .filter((a) => stageMatches(a, filter.stage, today))
    .filter((a) => !needle || `${a.candidate?.full_name ?? ''} ${a.job?.title ?? ''} ${a.candidate?.email ?? ''}`.toLowerCase().includes(needle))
    .sort((a, b) => b.received_at.localeCompare(a.received_at))
    .map((a) => ({
      id: a.id,
      jobId: a.job?.id ?? null,
      name: a.candidate?.full_name ?? 'Candidate',
      email: a.candidate?.email ?? null,
      position: a.job?.title ?? '—',
      company: a.job?.company?.name ?? '—',
      stage: a.stage_key,
      stageLabel: stageLabel(a.stage_key),
      subStatusKey: a.sub_status_key ?? null,
      notResponding: notResponding(outreachRowOf(a), today),
      received: shortDate(a.received_at.slice(0, 10)),
      owner: a.owner?.full_name ?? null,
      nextAction: a.next_action ? `${a.next_action}${a.next_action_due ? ` · due ${shortDate(a.next_action_due)}` : ''}` : null,
    }))
}
