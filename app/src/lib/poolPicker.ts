import { POOL_PAGE_SIZE } from '@/lib/candidatePool'

/**
 * "Source from the talent pool" on a job (plan 052; opens on a list since
 * 2026-10-08, HR's note "open a window with list, where we can do search").
 * With nothing typed it pages through the whole pool, most recently active
 * first — search_candidates' own order — and a term of two characters or
 * more narrows it. Pure shaping; the RPC decides who may see the pool.
 */

export const PICK_MIN_QUERY = 2

const count = new Intl.NumberFormat('en-GB')

/** The search term once it is long enough to search, else null (list everyone). */
function termOf(q: string): string | null {
  const term = q.trim()
  return term.length >= PICK_MIN_QUERY ? term : null
}

/** The search_candidates payload for page `page` (0-based). */
export function pickPayload(q: string, page: number): { q: string | null; limit: number; offset: number } {
  return { q: termOf(q), limit: POOL_PAGE_SIZE, offset: Math.max(0, page) * POOL_PAGE_SIZE }
}

function people(n: number): string {
  return `${count.format(n)} ${n === 1 ? 'person' : 'people'}`
}

/** "3,611 people · showing 50 · most recently active first", or the matches for a search. */
export function pickSummary(total: number, shown: number, q: string): string {
  const term = termOf(q)
  const showing = shown < total ? ` · showing ${count.format(shown)}` : ''
  if (!term) return `${people(total)} · showing ${count.format(shown)} · most recently active first`
  return `${people(total)} ${total === 1 ? 'matches' : 'match'} “${term}”${showing}`
}
