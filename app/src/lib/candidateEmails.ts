import { supabase } from '@/lib/supabase'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'

/**
 * Queue the rejection or withdrawal email for applications whose status is
 * already set (0102). The database skips anyone marked Do not contact, with
 * no email, or already written to; the server sends what is queued.
 */
export type EmailSkip = { name: string; why: 'do_not_contact' | 'no_email' | 'already' | 'status' | 'missing' }
export type EmailResult = { queued: number; skipped: EmailSkip[]; error: string | null }

export async function emailCandidates(applicationIds: ReadonlyArray<string>, kind: 'rejected' | 'withdrawn'): Promise<EmailResult> {
  const { data, error } = await supabase.rpc('email_candidates', { p_application_ids: [...new Set(applicationIds)], p_kind: kind })
  if (error) {
    console.error('email_candidates failed:', error.message)
    return { queued: 0, skipped: [], error: friendlyRecruitmentError(error.message) }
  }
  const body = (data ?? {}) as { queued?: number; skipped?: EmailSkip[] }
  return { queued: body.queued ?? 0, skipped: body.skipped ?? [], error: null }
}
