/**
 * Removing someone from the directory (task.md: "people & access, we need
 * delete"). It archives rather than deletes: 86 of the foreign keys pointing at
 * `people` are NO ACTION, so anyone with an employment, a document, a kudos or
 * a line of activity cannot be hard-deleted anyway — and the history that
 * blocks it is history worth keeping. Archiving hides the person from the
 * directory and every list that filters `archived_at`, and Restore puts them
 * back, so this is never a one-way door.
 *
 * Someone still employed is offboarded first; that flow ends the employment and
 * is what the record should show.
 */

export type RemovalVerdict = { canRemove: boolean; reason: string | null }

export function personRemovable(
  person: { employed: boolean; isSelf: boolean },
  isAdmin: boolean,
): RemovalVerdict {
  if (!isAdmin) return { canRemove: false, reason: 'Only platform admins remove people from the directory.' }
  if (person.isSelf) return { canRemove: false, reason: 'You cannot remove yourself from the directory.' }
  if (person.employed) {
    return { canRemove: false, reason: 'They still have a current employment. Offboard them first, then remove.' }
  }
  return { canRemove: true, reason: null }
}

/** What the confirm step says, so the wording lives with the rule. */
export function removalConfirmation(name: string): string {
  return `Remove ${name} from the directory? Their history stays, and you can restore them.`
}
