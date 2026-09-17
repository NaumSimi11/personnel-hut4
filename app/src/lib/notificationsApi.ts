import { supabase } from '@/lib/supabase'

/**
 * Kick the mail queue (plan 043): the database already created the
 * notifications for whatever just happened; the service sends the queued
 * emails and says how it went. Called after actions and on Home. Never an
 * error for the user — the in-app rows are there regardless.
 */
export type DeliveryReport = { sent: number; failed: number; skipped: number; pending: number; configured?: boolean; busy?: boolean }

async function kick(path: string): Promise<DeliveryReport | null> {
  try {
    const { data } = await supabase.auth.getSession()
    const token = data.session?.access_token
    if (!token) return null
    const response = await fetch(path, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(20_000),
    })
    if (!response.ok) return null
    return (await response.json()) as DeliveryReport
  } catch (e) {
    console.warn(`Delivery kick ${path} failed:`, e instanceof Error ? e.message : e)
    return null
  }
}

/** The notification queue, and the handover queue behind it (plan 048) — one kick sends both. */
export async function deliverNotifications(): Promise<DeliveryReport | null> {
  const [notifications] = await Promise.all([kick('/api/notifications/deliver'), kick('/api/handover/deliver')])
  return notifications
}

/** The handover queue alone (plan 048): after Resend / Retry on a send. */
export function deliverHandover(): Promise<DeliveryReport | null> {
  return kick('/api/handover/deliver')
}

/** One sentence for a notice, the way the old HR said it. */
export function deliverySentence(report: DeliveryReport | null): string {
  if (!report) return 'Notifications are in the app; email delivery could not be reached.'
  if (report.configured === false) return 'Notified in the app. Email delivery is not configured yet, so nothing was sent.'
  const parts: string[] = []
  if (report.sent) parts.push(`${report.sent} email${report.sent === 1 ? '' : 's'} sent`)
  if (report.skipped) parts.push(`${report.skipped} without an address`)
  if (report.failed) parts.push(`${report.failed} failed`)
  if (report.pending) parts.push(`${report.pending} still queued`)
  return parts.length ? `Notified: ${parts.join(', ')}.` : 'Notified in the app.'
}
