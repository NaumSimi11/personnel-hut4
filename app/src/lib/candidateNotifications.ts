import { supabase } from './supabase'

export async function notifyCandidateAssignment(applicationId: string, version: string): Promise<string> {
  try {
    const { data } = await supabase.auth.getSession()
    if (!data.session) return 'Email not sent: sign in again.'
    const response = await fetch('/api/hiring/notify-assignment', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${data.session.access_token}` },
      body: JSON.stringify({ applicationId, version }),
      signal: AbortSignal.timeout(15000),
    })
    const result = await response.json() as { emailSent?: boolean; message?: string }
    return result.emailSent ? 'Assignment email sent; the task is available on the owner’s Home page.' : result.message ?? 'Email not sent. Please contact the owner directly.'
  } catch { return 'Email delivery could not be confirmed. Please contact the owner directly.' }
}
