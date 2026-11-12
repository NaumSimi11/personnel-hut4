import { supabase } from '@/lib/supabase'

/**
 * Hold, resume and cancel a hiring request (0101; spec 8.1–8.3). The
 * database is the rule; this decides which buttons show and words the
 * answers. "HR or the requester" may steer: the requester, or anyone with
 * jobs.approve or jobs.edit in the company.
 */
export type LifecycleRequest = { status: string; requested_by: string | null; company_id: string }
export type Viewer = { personId: string | null; can: (companyId: string, cap: string) => boolean }
export type LifecycleActions = { hold: boolean; resume: boolean; cancel: boolean }

const HOLDABLE = new Set(['submitted', 'approved'])
const FINAL = new Set(['filled', 'cancelled', 'rejected'])
export const DEFAULT_REVIEW_DAYS = 14

export function maySteer(r: LifecycleRequest, viewer: Viewer): boolean {
  return (
    (viewer.personId !== null && r.requested_by === viewer.personId) ||
    viewer.can(r.company_id, 'jobs.approve') ||
    viewer.can(r.company_id, 'jobs.edit')
  )
}

export function lifecycleActions(r: LifecycleRequest, viewer: Viewer): LifecycleActions {
  if (!maySteer(r, viewer)) return { hold: false, resume: false, cancel: false }
  return { hold: HOLDABLE.has(r.status), resume: r.status === 'on_hold', cancel: !FINAL.has(r.status) }
}

/** The review date `days` from `today` (YYYY-MM-DD), in UTC like the database's dates. */
export function reviewDate(today: string, days: number): string {
  const d = new Date(`${today}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + Math.max(0, Math.floor(days)))
  return d.toISOString().slice(0, 10)
}

export type LifecycleResult = { ok: true; data: Record<string, unknown> } | { ok: false; error: string }

async function call(fn: 'hold_hiring_request' | 'resume_hiring_request' | 'cancel_hiring_request', args: Record<string, unknown>): Promise<LifecycleResult> {
  const { data, error } = await supabase.rpc(fn as never, args as never)
  if (error) {
    console.error(`${fn} failed:`, error.message)
    return { ok: false, error: error.message }
  }
  return { ok: true, data: (data ?? {}) as Record<string, unknown> }
}

export const holdRequest = (id: string, reason: string, reviewOn: string | null) =>
  call('hold_hiring_request', { p_request_id: id, p_reason: reason, p_review_on: reviewOn })
export const resumeRequest = (id: string) => call('resume_hiring_request', { p_request_id: id })
export const cancelRequest = (id: string, reason: string) => call('cancel_hiring_request', { p_request_id: id, p_reason: reason })

/** What the page says after a cancel: how many candidates are still in play on the closed jobs. */
export function cancelNotice(data: Record<string, unknown>): string {
  const inPlay = Number(data.in_play ?? 0)
  const jobs = Array.isArray(data.jobs_closed) ? data.jobs_closed.length : 0
  const closed = jobs ? ` ${jobs === 1 ? 'Its job is' : `Its ${jobs} jobs are`} closed.` : ''
  if (!inPlay) return `Request cancelled.${closed}`
  return `Request cancelled.${closed} ${inPlay} candidate${inPlay === 1 ? ' is' : 's are'} still in play — reject or withdraw them from Applicants.`
}
