import { supabase } from '@/lib/supabase'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'

/**
 * The one door for moving an application (plan 075): every move, reject and
 * withdrawal sets a status through `set_application_status`, and the status
 * carries its stage. The RPC writes the timeline event (the note is its body)
 * and refuses what may not happen — a closed job, a hire, "Hired" itself —
 * in words fit to show as they are.
 */
export type StatusResult = { set: number; error: string | null }

/** A rejected status needs one of HR's reason codes (0125, T9); the database refuses it otherwise. */
export async function setApplicationStatus(applicationIds: ReadonlyArray<string>, subStatusKey: string, note = '', reasonCode = ''): Promise<StatusResult> {
  const ids = [...new Set(applicationIds)]
  const { data, error } = await supabase.rpc('set_application_status', {
    p_application_ids: ids,
    p_sub_status_key: subStatusKey,
    p_note: note.trim(),
    ...(reasonCode ? { p_reason_code: reasonCode } : {}),
  })
  if (error) {
    console.error('set_application_status failed:', error.message)
    return { set: 0, error: friendlyRecruitmentError(error.message) }
  }
  return { set: (data as { set?: number } | null)?.set ?? ids.length, error: null }
}

/** The same sentence the database raises (0128): a hire follows an accepted offer. */
export const HIRE_NEEDS_OFFER =
  'Hired needs an accepted offer. Record the offer and the candidate\u2019s answer on the Offer tab first.'

/** Whether the application has an accepted offer, so Confirm hire can go ahead. */
export async function hasAcceptedOffer(applicationId: string): Promise<boolean> {
  const { data, error } = await supabase.from('offers').select('id').eq('application_id', applicationId).eq('status', 'accepted').limit(1)
  if (error) {
    console.error('Accepted offer check failed:', error.message)
    return false
  }
  return (data ?? []).length > 0
}
