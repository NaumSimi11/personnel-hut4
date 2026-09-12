import { supabase } from '@/lib/supabase'

/**
 * Tell people about a leave event through the service (../server): the
 * approvers about a new request or an ask to cancel, the person about the
 * decision. The database action has already happened; a failure here is
 * logged and never shown as an error — nothing the user did is undone.
 */
export type LeaveNotifyEvent = 'submitted' | 'approved' | 'rejected' | 'cancellation_asked'

export async function notifyLeave(requestId: string, event: LeaveNotifyEvent): Promise<void> {
  try {
    const { data } = await supabase.auth.getSession()
    const token = data.session?.access_token
    if (!token) return
    const response = await fetch('/api/leave/notify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ requestId, event }),
    })
    if (!response.ok) console.warn(`Leave notification (${event}) not sent: ${response.status}`)
  } catch (e) {
    console.warn(`Leave notification (${event}) failed:`, e instanceof Error ? e.message : e)
  }
}
