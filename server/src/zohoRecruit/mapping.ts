import { longDate } from './dates.js'

/**
 * The Zoho Recruit vocabulary → the app's (plan 052 §3.1). Every table here
 * is total over the export; an unknown value is a problem the extract
 * reports and exits on, never a guess.
 */

export type StageKey = 'new' | 'screening' | 'interview' | 'offer' | 'hired' | 'rejected' | 'withdrawn'
export type ContactFlag = 'do_not_contact' | 'contact_later'
/** `sub` is the D5 outreach sub-status backfill (plan 054); undefined outside new/screening's mapped statuses. */
export type StatusMapping = { stage: StageKey; reason?: string; flag?: ContactFlag; sub?: string }
export type JobStatus = 'open' | 'on_hold' | 'filled' | 'closed'

export const TERMINAL_STAGES: readonly StageKey[] = ['hired', 'rejected', 'withdrawn']

/** The 38 distinct `Candidate Status` values of Associated_001.csv, byte-exact. */
export const STATUS_TO_STAGE: Readonly<Record<string, StatusMapping>> = {
  // screening
  Contacted: { stage: 'screening', sub: 'contacted' },
  Interested: { stage: 'screening', sub: 'interested' },
  Qualified: { stage: 'screening', sub: 'qualified' },
  'Waiting-for-Evaluation': { stage: 'screening', sub: 'awaiting_evaluation' },
  // new
  Associated: { stage: 'new', sub: 'sourced' },
  New: { stage: 'new', sub: 'sourced' },
  'Attempted to Contact': { stage: 'new', sub: 'contact_attempted' },
  'Not Contacted': { stage: 'new', sub: 'contact_attempted' },
  'Not contacted': { stage: 'new', sub: 'contact_attempted' },
  // withdrawn
  'Not Interested': { stage: 'withdrawn', reason: 'Not interested' },
  'Not responding': { stage: 'withdrawn', reason: 'No response' },
  'Withdraw Application': { stage: 'withdrawn', reason: 'Candidate withdrew' },
  'NEVER to be contacted again': { stage: 'withdrawn', reason: 'Do not contact', flag: 'do_not_contact' },
  'Contact in Future': { stage: 'withdrawn', reason: 'Contact in future', flag: 'contact_later' },
  'Offer-Declined': { stage: 'withdrawn', reason: 'Offer declined' },
  // rejected
  Rejected: { stage: 'rejected', reason: 'Rejected' },
  'Rejected by hiring manager': { stage: 'rejected', reason: 'Rejected by the hiring manager' },
  'Rejected by HR': { stage: 'rejected', reason: 'Rejected by HR' },
  'Rejected by Manager - Interview': { stage: 'rejected', reason: 'Rejected by the manager after interview' },
  'Rejected-for-Interview': { stage: 'rejected', reason: 'Rejected for interview' },
  Unqualified: { stage: 'rejected', reason: 'Unqualified' },
  'Offer-Withdrawn': { stage: 'rejected', reason: 'Offer withdrawn' },
  'Rejected-Hirable': { stage: 'rejected', reason: 'Rejected, hirable later', flag: 'contact_later' },
  // interview
  'On-Hold': { stage: 'interview' },
  'Interview 1 - HR': { stage: 'interview' },
  'Interview 2 - Stakeholders': { stage: 'interview' },
  'Interview 3 - Other stakeholder': { stage: 'interview' },
  'Interview 4 - Other stakeholders': { stage: 'interview' },
  'Feedback to be provided from an Interview': { stage: 'interview' },
  'Interview-Scheduled': { stage: 'interview' },
  'Interview-to-be-Scheduled': { stage: 'interview' },
  'Interview-in-Progress': { stage: 'interview' },
  'Submitted-to-hiring manager': { stage: 'interview' },
  Task: { stage: 'interview' },
  'No-Show': { stage: 'interview' },
  // offer
  'Offer-Made': { stage: 'offer' },
  'To-be-Offered': { stage: 'offer' },
  // hired
  Hired: { stage: 'hired' },
}

export class UnknownValueError extends Error {}

export function mapStatus(status: string): StatusMapping {
  const found = Object.prototype.hasOwnProperty.call(STATUS_TO_STAGE, status) ? STATUS_TO_STAGE[status] : undefined
  if (!found) throw new UnknownValueError(`Unknown Zoho status "${status}"`)
  return { ...found }
}

/** The 10 distinct `Source` values of Candidates_001.csv; blank is `imported`. */
export const SOURCE_TO_KEY: Readonly<Record<string, string>> = {
  'Head Hunt': 'head_hunt',
  'Imported using Resume Extractor': 'linkedin_profile',
  'Advertisement Linkedin': 'linkedin_ad',
  CareerSite: 'careers_page',
  'Advertisement External Career Pages': 'job_board',
  Advertisement: 'job_board',
  'Employee Referral': 'referral',
  'External Referral': 'referral',
  'Added by User': 'added_by_hand',
  None: 'imported',
}

export function mapSource(source: string): string {
  if (source === '') return 'imported'
  const found = Object.prototype.hasOwnProperty.call(SOURCE_TO_KEY, source) ? SOURCE_TO_KEY[source] : undefined
  if (!found) throw new UnknownValueError(`Unknown Zoho source "${source}"`)
  return found
}

/** D1: Zoho departments → company short codes; Clip Media Group has no job or candidate. */
export const DEPARTMENT_TO_COMPANY: Readonly<Record<string, string | null>> = {
  'HUT 4': 'HUT4',
  'HUT 4 Capital': 'HUT4',
  'Corporate Services': 'HUT4',
  'Corporate Marketing': 'HUT4',
  Multihem: 'HUT4',
  'SYNAMI DOOEL': 'SYNA',
  'Synami Products': 'SYNA',
  'Synami Sales': 'SYNA',
  SNOWBALL: 'SNOW',
  Liquiditas: 'LIQU',
  'Clip Media Group': null,
}

/** A company code, null for a department without one, undefined when unmapped (the extract counts those). */
export function mapDepartment(name: string): string | null | undefined {
  return Object.prototype.hasOwnProperty.call(DEPARTMENT_TO_COMPANY, name) ? DEPARTMENT_TO_COMPANY[name] : undefined
}

export const JOB_STATUS_TO_STATUS: Readonly<Record<string, JobStatus>> = {
  Filled: 'filled',
  Cancelled: 'closed',
  'In-progress': 'open',
  Inactive: 'on_hold',
}

export function mapJobStatus(status: string): JobStatus {
  const found = Object.prototype.hasOwnProperty.call(JOB_STATUS_TO_STATUS, status) ? JOB_STATUS_TO_STATUS[status] : undefined
  if (!found) throw new UnknownValueError(`Unknown Zoho job status "${status}"`)
  return found
}

export type JobClose = { status: string; dateClosed: string | null; modifiedAt: string | null }
export type StaleVerdict =
  | { stale_closed: false }
  | { stale_closed: true; withdrawn_reason: 'Job closed'; close_date: string | null; close_date_assumed: boolean }

/**
 * D3: a non-terminal mapped stage on a Filled / Cancelled job is withdrawn
 * "Job closed" at the job's close; Cancelled jobs carry no Date Closed, so
 * the Modified Time stands in and the row says so.
 */
export function staleRule(stageKey: StageKey, job: JobClose): StaleVerdict {
  if (TERMINAL_STAGES.includes(stageKey)) return { stale_closed: false }
  if (job.status !== 'Filled' && job.status !== 'Cancelled') return { stale_closed: false }
  const assumed = job.dateClosed === null
  return {
    stale_closed: true,
    withdrawn_reason: 'Job closed',
    close_date: assumed ? job.modifiedAt : job.dateClosed,
    close_date_assumed: assumed,
  }
}

const MENTION = /recruit\[user#(\d+)#\d+\]recruit/g

/** `recruit[user#<id>#<n>]recruit` → `@Full Name`; the id is the Zoho user id without its prefix. */
export function rewriteMentions(body: string, users: ReadonlyMap<string, string>): string {
  return body.replace(MENTION, (_m, id: string) => `@${users.get(`Zrecruit_${id}`) ?? 'unknown user'}`)
}

/** `[Zoho Call · 12 Mar 2024 · Kristina Arsova]` — the note's type, local date and author. */
export function notePrefix(type: string, iso: string, actor: string, tz: string): string {
  return `[Zoho ${type} · ${longDate(iso, tz)} · ${actor}]`
}
