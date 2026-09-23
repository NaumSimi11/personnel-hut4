/**
 * One rule for deleting, across the app (plan 063).
 *
 *     Delete is for a mistake. Archive is for history.
 *     A thing may be deleted only while nothing has happened to it.
 *
 * `hiringDelete.ts` already said this for jobs and hiring requests; these are
 * the two that were answered differently — a policy and a candidate could only
 * ever be archived. The database decides (0080); this is the same rule read
 * ahead of the click, so a disabled button explains itself instead of a
 * refusal arriving after it.
 */

export type Verdict = { canDelete: boolean; reason: string | null }

const ALLOWED: Verdict = { canDelete: true, reason: null }
/** `many` is given where English refuses to just add an s. */
const plural = (n: number, one: string, many = `${one}s`): string => `${n} ${n === 1 ? one : many}`

/** A policy goes while nobody has agreed to it. */
export function policyDeletable(
  policy: { acknowledgements: number; status: string },
  permitted: boolean,
): Verdict {
  if (!permitted) return { canDelete: false, reason: 'You cannot change policies here.' }
  if (policy.acknowledgements > 0) {
    const n = policy.acknowledgements
    return {
      canDelete: false,
      reason: `${plural(n, 'person', 'people')} already agreed to this. Archive it instead, so their record still means something.`,
    }
  }
  return ALLOWED
}

/**
 * What an edit may touch. The title and summary are how a policy is referred
 * to and may be corrected whenever; the body is what people agreed to, so once
 * published it changes only by publishing a new version.
 */
export const bodyEditable = (policy: { status: string }): boolean => policy.status === 'draft'

/** A candidate goes while they are nothing but a name. */
export function candidateDeletable(
  candidate: { applications: number; notes: number; files: number; do_not_contact: boolean },
  permitted: boolean,
): Verdict {
  if (!permitted) return { canDelete: false, reason: 'Deleting a candidate needs "Work the talent pool".' }
  if (candidate.do_not_contact) {
    return {
      canDelete: false,
      reason:
        'They asked never to be contacted again. That has to be remembered, or they will be sourced afresh next week. Archive them instead.',
    }
  }
  if (candidate.applications > 0) {
    return { canDelete: false, reason: `${plural(candidate.applications, 'application')} on record. Archive them instead.` }
  }
  if (candidate.notes > 0) {
    return { canDelete: false, reason: `${plural(candidate.notes, 'note')} about them. Archive them instead, so it is not lost.` }
  }
  if (candidate.files > 0) {
    return { canDelete: false, reason: `${plural(candidate.files, 'document')} on file. Archive them instead.` }
  }
  return ALLOWED
}

export function friendlyHardDeleteError(message: string): string {
  if (/row-level security/i.test(message)) return 'You cannot delete this.'
  if (/schema cache|could not find the function/i.test(message)) {
    return 'This app is newer than the database it is talking to. Tell whoever deploys it.'
  }
  return message
}
