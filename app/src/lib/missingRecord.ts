/**
 * The message a detail page shows when the record it asked for came back empty.
 *
 * Row-level security filters rows rather than raising an error, so "deleted"
 * and "hidden from you" arrive at the client as the same empty result. A page
 * that picks one of those and states it as fact will sooner or later state the
 * wrong one, and send whoever reads it looking for a bug that is not there.
 *
 * So this says only what the caller can actually prove:
 *   - the query failed        → the lookup is at fault, say nothing about access
 *   - the viewer sees all     → visibility was guaranteed, so the row is gone
 *   - anything else           → both remain possible; keep both open
 */
export type MissingRecord = {
  /** The record as it reads mid-sentence: 'person', 'company', 'job'. */
  readonly noun: string
  /** True when the query itself errored, as opposed to returning nothing. */
  readonly lookupFailed: boolean
  /**
   * True when the viewer's sight is unrestricted (a platform admin), which
   * makes an empty result proof of deletion rather than a hint about access.
   */
  readonly seesEverything: boolean
  /** The pronoun for the record; defaults to 'them'. */
  readonly plural?: string
}

export function missingRecordMessage(record: MissingRecord): string {
  if (record.lookupFailed) {
    return `Could not load this ${record.noun}. Please try again.`
  }
  if (record.seesEverything) {
    return `This ${record.noun} no longer exists — the record was deleted.`
  }
  const pronoun = record.plural ?? 'them'
  return `This ${record.noun} does not exist, or you do not have access to ${pronoun}.`
}
