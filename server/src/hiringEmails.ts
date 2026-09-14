/**
 * Hiring-manager notifications (plan 043). Two moments: assigned on a
 * submitted request — which is awaiting approval and is not a go-ahead —
 * and the approval, after which recruitment can proceed. The target start
 * date is the employee's, never a deadline for the manager.
 */

export type ManagerEvent = 'assigned' | 'approved'

export type ManagerEmailInput = {
  role: string
  company: string
  requester: string | null
  approver: string | null
  targetStart: string | null
  url: string
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string)
}

export function buildManagerEmail(event: ManagerEvent, input: ManagerEmailInput): { subject: string; html: string } {
  const role = escapeHtml(input.role)
  const company = escapeHtml(input.company)
  const start = `<p>Target employee start: <strong>${escapeHtml(input.targetStart ?? 'Not set')}</strong> — the date the person should begin, not a deadline for you.</p>`
  if (event === 'assigned') {
    return {
      subject: `You are the hiring manager for ${input.role}`,
      html: [
        `<p>You've been assigned as hiring manager for <strong>${role}</strong> at <strong>${company}</strong>${input.requester ? ` by ${escapeHtml(input.requester)}` : ''}.</p>`,
        start,
        `<p>Request status: <strong>Awaiting approval</strong>. The assignment does not authorize recruitment to begin; you will hear again once the request is approved.</p>`,
        `<p><a href="${escapeHtml(input.url)}">View request</a></p>`,
      ].join('\n'),
    }
  }
  return {
    subject: `Recruitment can proceed: ${input.role}`,
    html: [
      `<p>The hiring request for <strong>${role}</strong> at <strong>${company}</strong> has been <strong>approved</strong>${input.approver ? ` by ${escapeHtml(input.approver)}` : ''}. Recruitment can proceed.</p>`,
      start,
      `<p><a href="${escapeHtml(input.url)}">Prepare the role</a></p>`,
    ].join('\n'),
  }
}

/** The event must be what the record shows — a stale or replayed call mails nothing. */
export function managerEventMatches(event: ManagerEvent, r: { status: string; hiring_manager_id: string | null }): boolean {
  if (!r.hiring_manager_id) return false
  return event === 'assigned' ? r.status === 'submitted' : r.status === 'approved'
}
