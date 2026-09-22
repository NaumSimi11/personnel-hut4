import { supabase } from '@/lib/supabase'

/**
 * Notes on the person (plan 055): the calls, messages and status changes
 * that were about the candidate and not about one job — Zoho's person-level
 * history, and what a pool holder writes from the record. The database
 * decides everything: add_candidate_note is the one door in, the sel policy
 * (pool holders, or candidates.view in the tagged company) decides who
 * reads, the del policy (the author, or an admin) decides who removes. This
 * file phrases the rows and carries the calls.
 */

export const NOTE_KINDS = [
  { key: 'note', label: 'Note' },
  { key: 'call', label: 'Call' },
  { key: 'message', label: 'Message' },
  { key: 'meeting', label: 'Meeting' },
  { key: 'status_change', label: 'Status change' },
  { key: 'association', label: 'Added to a job' },
  { key: 'unassociation', label: 'Removed from a job' },
  { key: 'review', label: 'Review' },
  { key: 'task', label: 'Task' },
  { key: 'other', label: 'Other' },
] as const

export type NoteKind = (typeof NOTE_KINDS)[number]['key']

/** Newest first, this many a page; "Show more" asks for the next page. */
export const NOTES_PAGE_SIZE = 50

/** The name an imported note falls back to when no actor was kept at all. */
export const NOTE_ACTOR_FALLBACK = 'Zoho Recruit'

export const NOTE_REMOVE_REFUSED = 'You do not have permission to remove this note.'

export type CandidateNoteRow = {
  id: string
  kind: string
  body: string
  actor_id: string | null
  actor_name: string | null
  occurred_at: string
  actor: { full_name: string } | null
}

export function noteKindLabel(kind: string): string {
  return NOTE_KINDS.find((k) => k.key === kind)?.label ?? kind
}

/** The linked person, else the Zoho user we could not link, else the system. */
export function noteActor(n: Pick<CandidateNoteRow, 'actor' | 'actor_name'>): string {
  return n.actor?.full_name ?? n.actor_name ?? NOTE_ACTOR_FALLBACK
}

/** The del policy as a hint: the author's own note, or any note for an admin. */
export function canRemoveNote(
  n: Pick<CandidateNoteRow, 'actor_id'>,
  viewer: { personId: string | null; isAdmin: boolean },
): boolean {
  if (viewer.isAdmin) return true
  return n.actor_id !== null && n.actor_id === viewer.personId
}

/** Page `page` (0-based) of the candidate's notes, newest first. */
export async function listCandidateNotes(candidateId: string, page: number): Promise<CandidateNoteRow[]> {
  const from = Math.max(0, page) * NOTES_PAGE_SIZE
  const { data, error } = await supabase
    .from('candidate_notes')
    .select(
      `id, kind, body, actor_id, actor_name, occurred_at,
       actor:people!candidate_notes_actor_id_fkey(full_name)`,
    )
    .eq('candidate_id', candidateId)
    .order('occurred_at', { ascending: false })
    .order('created_at', { ascending: false })
    .range(from, from + NOTES_PAGE_SIZE - 1)
  if (error) throw new Error(error.message)
  return (data ?? []) as CandidateNoteRow[]
}

/** add_candidate_note: the RPC trims, checks and refuses in its own words. */
export async function addCandidateNote(candidateId: string, body: string): Promise<string> {
  const { data, error } = await supabase.rpc('add_candidate_note', { p_candidate_id: candidateId, p_body: body })
  if (error) throw new Error(error.message)
  const id = data && typeof data === 'object' && !Array.isArray(data) ? data.id : null
  if (typeof id !== 'string') throw new Error('The note was not saved.')
  return id
}

/** RLS refuses by matching zero rows, not by erroring — select the row back. */
export async function removeCandidateNote(noteId: string): Promise<void> {
  const { data, error } = await supabase.from('candidate_notes').delete().eq('id', noteId).select('id')
  if (error) throw new Error(error.message)
  if (!data?.length) throw new Error(NOTE_REMOVE_REFUSED)
}
