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

export async function setApplicationStatus(applicationIds: ReadonlyArray<string>, subStatusKey: string, note = ''): Promise<StatusResult> {
  const ids = [...new Set(applicationIds)]
  const { data, error } = await supabase.rpc('set_application_status', {
    p_application_ids: ids,
    p_sub_status_key: subStatusKey,
    p_note: note.trim(),
  })
  if (error) {
    console.error('set_application_status failed:', error.message)
    return { set: 0, error: friendlyRecruitmentError(error.message) }
  }
  return { set: (data as { set?: number } | null)?.set ?? ids.length, error: null }
}
