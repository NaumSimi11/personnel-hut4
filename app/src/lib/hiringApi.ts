import { supabase } from '@/lib/supabase'

/**
 * Tell the hiring manager where their request stands, through the service
 * (../server): assigned on submit, go-ahead on approval. The request is
 * already saved; the answer is a sentence for the notice ("Ana was
 * emailed." / "Email delivery is not configured; …") and never an error.
 */
export type ManagerNotifyEvent = 'assigned' | 'approved'

export async function notifyHiringManager(requestId: string, event: ManagerNotifyEvent): Promise<string> {
  try {
    const { data } = await supabase.auth.getSession()
    const token = data.session?.access_token
    if (!token) return 'The hiring manager was not notified: sign in again.'
    const response = await fetch('/api/hiring/notify-manager', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ requestId, event }),
      signal: AbortSignal.timeout(15_000),
    })
    const result = (await response.json().catch(() => ({}))) as { emailSent?: boolean; message?: string; error?: string }
    if (!response.ok) return `The hiring manager was not notified: ${result.error ?? `request failed (${response.status})`}.`
    return result.message ?? (result.emailSent ? 'The hiring manager was emailed.' : 'The hiring manager was not emailed.')
  } catch (e) {
    console.warn(`Hiring manager notification (${event}) failed:`, e instanceof Error ? e.message : e)
    return 'The hiring manager could not be notified right now; tell them directly.'
  }
}
