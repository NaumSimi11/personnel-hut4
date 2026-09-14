import type { RouteLocationRaw } from 'vue-router'

/**
 * Home queue rows for the modules that arrived after the first queue
 * (plan 034): compensation decisions, document reviews, uploads asked of
 * me, policies to read, IT requests I can work, payroll to approve. RLS
 * already trims what each viewer can read; these converters apply the
 * "is it mine to act on" rules the functions enforce, so a row is only
 * offered when the click can succeed.
 */

export type QueueRow = {
  id: string
  title: string
  sub: string
  actionLabel: string
  to: RouteLocationRaw
}

export type Viewer = { personId: string | null; can: (companyId: string, cap: string) => boolean }

type Named = { full_name: string } | null
type Company = { name: string } | null

export type CompensationQueueRow = {
  id: string
  proposed_by: string | null
  period: { person_id: string; company_id: string; person: Named; company: Company } | null
}

export function compensationToRows(rows: CompensationQueueRow[], viewer: Viewer): QueueRow[] {
  return rows
    .filter((r) => r.period && viewer.can(r.period.company_id, 'salary.approve') && r.proposed_by !== viewer.personId)
    .map((r) => ({
      id: `comp-${r.id}`,
      title: `Compensation: ${r.period!.person?.full_name ?? '—'}`,
      sub: `${r.period!.company?.name ?? '—'} · proposal awaiting your decision`,
      actionLabel: 'Decide',
      to: { name: 'person', params: { personId: r.period!.person_id } },
    }))
}

export type DocumentReviewRow = {
  id: string
  person_id: string
  company_id: string
  category_key: string
  person: Named
  category: { label: string } | null
}

export function documentReviewsToRows(rows: DocumentReviewRow[], viewer: Viewer): QueueRow[] {
  return rows
    .filter((r) => viewer.can(r.company_id, 'documents.request'))
    .map((r) => ({
      id: `docreq-${r.id}`,
      title: `Document to review: ${r.category?.label ?? r.category_key}`,
      sub: `${r.person?.full_name ?? '—'} submitted it`,
      actionLabel: 'Review',
      to: { name: 'person', params: { personId: r.person_id } },
    }))
}

export type MyRequestRow = { id: string; category: { label: string } | null; company: Company; due_date: string | null }

export function myRequestsToRows(rows: MyRequestRow[]): QueueRow[] {
  return rows.map((r) => ({
    id: `myreq-${r.id}`,
    title: `Upload: ${r.category?.label ?? 'a document'}`,
    sub: `${r.company?.name ?? '—'} asked for it${r.due_date ? ` · due ${r.due_date}` : ''}`,
    actionLabel: 'Upload',
    to: { name: 'my-workspace' },
  }))
}

export type PolicyQueueRow = { id: string; title: string; version: number; company: Company }
export type AckLite = { policy_id: string; version: number }

export function policiesToRows(policies: PolicyQueueRow[], acks: AckLite[]): QueueRow[] {
  return policies
    .filter((p) => !acks.some((a) => a.policy_id === p.id && a.version === p.version))
    .map((p) => {
      const outdated = acks.some((a) => a.policy_id === p.id)
      return {
        id: `policy-${p.id}`,
        title: `Policy: ${p.title}`,
        sub: `${p.company?.name ?? 'Holding-wide'} · ${outdated ? 'new version to read and acknowledge' : 'please read and acknowledge'}`,
        actionLabel: 'Read',
        to: { name: 'my-workspace' },
      }
    })
}

export type ItQueueRow = {
  id: string
  title: string
  status: string
  company_id: string
  assignee_id: string | null
  person: Named
  company: Company
}

export function itRequestsToRows(rows: ItQueueRow[], viewer: Viewer): QueueRow[] {
  return rows
    // An assignee acts only with it.complete (advance_it_request); it.view alone would dead-end.
    .filter(
      (r) =>
        viewer.can(r.company_id, 'it.assign') ||
        (r.assignee_id !== null && r.assignee_id === viewer.personId && viewer.can(r.company_id, 'it.complete')),
    )
    .map((r) => ({
      id: `it-${r.id}`,
      title: `IT request: ${r.title}`,
      sub: `${r.company?.name ?? '—'} · for ${r.person?.full_name ?? '—'}${r.status === 'blocked' ? ' · blocked' : ''}`,
      actionLabel: 'Work it',
      to: { name: 'company', params: { companyId: r.company_id }, query: { tab: 'equipment' } },
    }))
}

export type PayrollQueueRow = {
  id: string
  company_id: string
  period_start: string
  period_end: string
  currency: string
  prepared_by: string | null
  company: Company
}

export function payrollToRows(rows: PayrollQueueRow[], viewer: Viewer): QueueRow[] {
  return rows
    .filter((r) => viewer.can(r.company_id, 'payroll.approve') && r.prepared_by !== viewer.personId)
    .map((r) => ({
      id: `payroll-${r.id}`,
      title: `Payroll: ${r.period_start} → ${r.period_end} ${r.currency}`,
      sub: `${r.company?.name ?? '—'} · prepared, awaiting your approval`,
      actionLabel: 'Review',
      to: { name: 'company', params: { companyId: r.company_id }, query: { tab: 'payroll' } },
    }))
}

export type LeaveQueueRow = {
  id: string
  person_id: string
  company_id: string
  leave_type_key: string
  start_date: string
  end_date: string
  working_days: number
  status: string
  cancellation_requested_at: string | null
  cancellation_declined_at: string | null
  person: Named
  company: Company
}

/** Pending requests and open cancellation asks for leave.approve holders — never one's own (decide_leave refuses). */
export function leaveToRows(rows: LeaveQueueRow[], viewer: Viewer): QueueRow[] {
  const askOpen = (r: LeaveQueueRow) =>
    r.status === 'approved' &&
    r.cancellation_requested_at !== null &&
    (r.cancellation_declined_at === null || r.cancellation_declined_at < r.cancellation_requested_at)
  return rows
    .filter((r) => viewer.can(r.company_id, 'leave.approve') && r.person_id !== viewer.personId)
    .filter((r) => r.status === 'pending' || askOpen(r))
    .map((r) => ({
      id: `leave-${r.id}`,
      title: `Leave: ${r.person?.full_name ?? '—'}`,
      sub:
        r.status === 'pending'
          ? `${r.company?.name ?? '—'} · ${r.leave_type_key} ${r.start_date} → ${r.end_date} (${r.working_days} days) awaiting your decision`
          : `${r.company?.name ?? '—'} · asks to cancel approved leave ${r.start_date} → ${r.end_date}`,
      actionLabel: 'Decide',
      to: { name: 'leave', query: { tab: 'requests' } },
    }))
}

export type HiringManagerRow = {
  id: string
  company_id: string
  title: string
  status: string
  target_start_date: string | null
  requester: Named
  company: Company
  jobs: { id: string; status: string }[]
}

/**
 * What the assigned hiring manager sees (plan 043): a submitted request is
 * awaiting approval — assignment is not a go-ahead; an approved one means
 * recruitment can proceed, until the job is open. Only where the viewer may
 * open it: assigning a manager grants no access by itself.
 */
export function hiringManagerToRows(rows: HiringManagerRow[], viewer: Viewer): QueueRow[] {
  const start = (r: HiringManagerRow) => ` · target start ${r.target_start_date ?? 'not set'}`
  return rows
    .filter((r) => viewer.can(r.company_id, 'jobs.view'))
    .filter((r) => r.status === 'submitted' || r.status === 'changes_requested' || (r.status === 'approved' && !r.jobs.some((j) => j.status === 'open')))
    .map((r) => ({
      id: `manager-${r.id}`,
      title: `Hiring manager: ${r.title}`,
      sub:
        r.status === 'approved'
          ? `${r.company?.name ?? '—'} · approved — recruitment can proceed${start(r)}`
          : `${r.company?.name ?? '—'} · requested by ${r.requester?.full_name ?? '—'} · ${r.status === 'changes_requested' ? 'changes requested' : 'awaiting approval'} — recruitment has not started${start(r)}`,
      actionLabel: r.status === 'approved' ? 'Prepare the role' : 'View request',
      to: { name: 'hiring' },
    }))
}
