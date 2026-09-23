/**
 * Undoing an attachment (plan 060).
 *
 * `detach_candidate_from_job` (0074) is the rule; this is the same rule read
 * ahead of the click, so a disabled button can say why instead of a refusal
 * arriving after it. The database stays the authority — this only ever agrees
 * with it or is out of date, never more permissive.
 *
 * An attachment may be undone while it is still nothing but an attachment.
 * Once anything has happened it is history: reject it or withdraw it, and the
 * trail keeps the truth.
 */

export type DetachTarget = {
  stage_key: string
  /** Somebody is carrying this one: they were emailed about it. */
  owner_id: string | null
  next_action: string | null
  /** Set once somebody was hired from it. */
  employment_period_id: string | null
  /** Set when the row came from an import rather than from somebody here. */
  source_provider: string | null
  events: number
  interviews: number
  offers: number
  files: number
}

export type DetachVerdict = { canDetach: boolean; reason: string | null }

const ALLOWED: DetachVerdict = { canDetach: true, reason: null }

/** Why this attachment cannot simply be taken back, or null when it can. */
export function detachable(row: DetachTarget, permitted: boolean): DetachVerdict {
  if (!permitted) return { canDetach: false, reason: 'You cannot change applications in this company.' }
  if (row.source_provider) {
    return {
      canDetach: false,
      reason: `This came from ${row.source_provider}, so it is history rather than a mistake. Reject or withdraw it instead.`,
    }
  }
  if (row.employment_period_id) {
    return { canDetach: false, reason: 'Somebody was hired from this application. It stays on the record.' }
  }
  if (row.owner_id || row.next_action) {
    return { canDetach: false, reason: 'This is assigned to somebody. Take the owner off it first.' }
  }
  if (row.stage_key !== 'new') {
    return { canDetach: false, reason: 'This has already moved on from New. Reject or withdraw it instead.' }
  }
  if (row.interviews > 0) return { canDetach: false, reason: 'There is an interview on this application.' }
  if (row.offers > 0) return { canDetach: false, reason: 'There is an offer on this application.' }
  if (row.files > 0) return { canDetach: false, reason: 'A file was filed against this application.' }
  if (row.events > 0) return { canDetach: false, reason: 'Something has already been recorded against this application.' }
  return ALLOWED
}

/** PostgREST answers an embedded count as `[{count: n}]`, or nothing at all. */
export const countOf = (rows: ReadonlyArray<{ count: number }> | null | undefined): number => rows?.[0]?.count ?? 0

export function friendlyDetachError(message: string): string {
  if (/row-level security/i.test(message)) return 'You cannot change applications in this company.'
  // PostgREST's words for a function the database has not got yet; a person
  // reading "schema cache" learns nothing they can act on.
  if (/schema cache|could not find the function/i.test(message)) {
    return 'This app is newer than the database it is talking to. Tell whoever deploys it.'
  }
  // detach_candidate_from_job raises sentences already written for a person.
  return message
}
