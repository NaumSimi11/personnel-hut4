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

// ------------------------------------------------------------------ delete
/**
 * Deleting outright (plan 067). Remove archives and is for a real person;
 * delete is for a record that should never have been, and since 0087 it can
 * take a whole history with it. Admins only, and never yourself.
 */
export type DeletionVerdict = { canDelete: boolean; reason: string | null }

export function personDeletable(person: { isSelf: boolean }, isAdmin: boolean): DeletionVerdict {
  if (!isAdmin) return { canDelete: false, reason: 'Only platform admins delete people.' }
  if (person.isSelf) return { canDelete: false, reason: 'You cannot delete yourself.' }
  return { canDelete: true, reason: null }
}

/** What `person_delete_cost` counts: what a forced delete takes with it. */
export type DeletionCost = {
  employments: number
  leave_requests: number
  documents: number
  kudos: number
  tasks: number
  equipment: number
  checklists: number
  has_sign_in: boolean
}

const COST_WORDS: { key: Exclude<keyof DeletionCost, 'has_sign_in'>; one: string; many: string }[] = [
  { key: 'employments', one: 'employment', many: 'employments' },
  { key: 'leave_requests', one: 'leave request', many: 'leave requests' },
  { key: 'documents', one: 'document', many: 'documents' },
  { key: 'kudos', one: 'kudos', many: 'kudos' },
  { key: 'tasks', one: 'task', many: 'tasks' },
  { key: 'equipment', one: 'equipment record', many: 'equipment records' },
  { key: 'checklists', one: 'checklist', many: 'checklists' },
]

/** True once anything is on record, which is when `delete_person` needs `p_force`. */
export function deletionNeedsForce(cost: DeletionCost): boolean {
  return cost.has_sign_in || COST_WORDS.some(({ key }) => cost[key] > 0)
}

/** "2 employments, 14 leave requests, and their sign-in" — said before the click, never after. */
export function deletionSummary(cost: DeletionCost): string {
  const parts = COST_WORDS.filter(({ key }) => cost[key] > 0).map(
    ({ key, one, many }) => `${cost[key]} ${cost[key] === 1 ? one : many}`,
  )
  const all = cost.has_sign_in ? [...parts, 'their sign-in'] : parts
  if (all.length === 0) return 'nothing else on record'
  if (all.length === 1) return all[0]!
  return `${all.slice(0, -1).join(', ')}, and ${all[all.length - 1]}`
}
