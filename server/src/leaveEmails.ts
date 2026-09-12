import { env } from './env.js'

/**
 * Leave notifications, ported from Field Notebook: approvers hear about a
 * new request (and about an ask to cancel), the person hears the decision
 * with what is left. Mail failure never breaks the action — the route
 * reports emailSent=false and the app moves on.
 */

export type LeaveEvent = 'submitted' | 'approved' | 'rejected' | 'cancellation_asked'

export type LeaveEmailInput = {
  personName: string
  personEmail: string | null
  companyName: string
  leaveType: string
  startDate: string
  endDate: string
  workingDays: number
  remaining: number | null
  note?: string | null
  decisionNote?: string | null
}

function escapeHtml(value: string | number): string {
  return String(value).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string,
  )
}

const days = (n: number) => `${n} working day${n === 1 ? '' : 's'}`

export function buildLeaveEmail(event: LeaveEvent, input: LeaveEmailInput): { subject: string; html: string } {
  const appUrl = env('APP_BASE_URL')?.replace(/\/+$/, '')
  const link = appUrl ? `<p><a href="${escapeHtml(appUrl)}/leave?tab=requests">Open Personnel</a></p>` : ''
  const span = `<strong>${escapeHtml(input.startDate)}</strong> to <strong>${escapeHtml(input.endDate)}</strong> (${escapeHtml(days(input.workingDays))})`
  const note = input.note ? `<blockquote>${escapeHtml(input.note)}</blockquote>` : ''
  switch (event) {
    case 'submitted':
      return {
        subject: `New leave request · ${input.personName}`,
        html: [
          `<p>Hello,</p>`,
          `<p><strong>${escapeHtml(input.personName)}</strong> (${escapeHtml(input.companyName)}) asks for <strong>${escapeHtml(input.leaveType)}</strong>: ${span}.</p>`,
          note,
          `<p>Please decide it in Personnel.</p>`,
          link,
        ].join('\n'),
      }
    case 'cancellation_asked':
      return {
        subject: `Asks to cancel leave · ${input.personName}`,
        html: [
          `<p>Hello,</p>`,
          `<p><strong>${escapeHtml(input.personName)}</strong> (${escapeHtml(input.companyName)}) asks to cancel approved <strong>${escapeHtml(input.leaveType)}</strong>: ${span}.</p>`,
          note,
          `<p>Cancel it or keep it in Personnel.</p>`,
          link,
        ].join('\n'),
      }
    case 'approved':
    case 'rejected': {
      const left = input.remaining === null ? '' : `<p>Leave left this year: <strong>${escapeHtml(input.remaining)} day${input.remaining === 1 ? '' : 's'}</strong>.</p>`
      const why = input.decisionNote ? `<blockquote>${escapeHtml(input.decisionNote)}</blockquote>` : ''
      return {
        subject: `Leave request ${event} · ${input.personName}`,
        html: [
          `<p>Hello ${escapeHtml(input.personName)},</p>`,
          `<p>Your <strong>${escapeHtml(input.leaveType)}</strong> request for ${span} has been <strong>${event}</strong>.</p>`,
          why,
          left,
          link ? link.replace('?tab=requests', '').replace('/leave', '/me') : '',
        ].join('\n'),
      }
    }
  }
}

/** Who gets which mail. Approvers are resolved by the route; the person's address comes from the record. */
export function leaveRecipients(event: LeaveEvent, input: LeaveEmailInput, approvers: string[]): string[] {
  if (event === 'submitted' || event === 'cancellation_asked') return approvers
  return input.personEmail ? [input.personEmail] : []
}

/** Send via Resend when configured; throw otherwise so the caller reports emailSent=false. */
export async function sendLeaveEmail(to: string[], message: { subject: string; html: string }): Promise<void> {
  const apiKey = env('RESEND_API_KEY')
  const from = env('EMAIL_FROM')
  if (!apiKey || !from) throw new Error('Email delivery is not configured (RESEND_API_KEY / EMAIL_FROM)')
  if (!to.length) throw new Error('Nobody to send to')
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to, subject: message.subject, html: message.html }),
  })
  if (!response.ok) throw new Error(`Resend responded ${response.status}`)
}

/** The event must be what the record shows — a replayed or stale call mails nothing. */
export function eventMatchesRequest(
  event: LeaveEvent,
  r: { status: string; cancellation_requested_at: string | null; cancellation_declined_at: string | null },
): boolean {
  switch (event) {
    case 'submitted':
      return r.status === 'pending'
    case 'approved':
    case 'rejected':
      return r.status === event
    case 'cancellation_asked':
      return (
        r.status === 'approved' &&
        r.cancellation_requested_at !== null &&
        (r.cancellation_declined_at === null || r.cancellation_declined_at < r.cancellation_requested_at)
      )
  }
}

/** One mail per request and event per window; in memory, per instance — enough to stop a click storm. */
export class NotifyThrottle {
  private readonly seen = new Map<string, number>()
  constructor(
    private readonly windowMs: number,
    private readonly now: () => number = Date.now,
  ) {}
  allow(requestId: string, event: LeaveEvent): boolean {
    const key = `${requestId}:${event}`
    const at = this.now()
    const last = this.seen.get(key)
    if (last !== undefined && at - last < this.windowMs) return false
    this.seen.set(key, at)
    if (this.seen.size > 5000) {
      for (const [k, v] of this.seen) if (at - v >= this.windowMs) this.seen.delete(k)
    }
    return true
  }
}
