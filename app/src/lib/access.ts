/**
 * Who has access to what (plan 061).
 *
 * The shaping around `person_access`: the order a list reads in, and the
 * sentence the card's heading says. The rules themselves are the database's
 * (0075) — this never decides anything, it only describes.
 */

export type AccessRow = {
  id: string
  system_key: string
  account: string | null
  status: 'granted' | 'revoked'
  note: string | null
  revoked_note: string | null
  granted_at: string
  revoked_at: string | null
  system: { label: string } | null
  granter: { full_name: string } | null
  revoker: { full_name: string } | null
}

/** By name, so the same person's list reads the same way every time. */
export function orderAccess<T extends { system: { label: string } | null; system_key: string }>(
  rows: ReadonlyArray<T>,
): T[] {
  return [...rows].sort((a, b) =>
    (a.system?.label ?? a.system_key).localeCompare(b.system?.label ?? b.system_key),
  )
}

const plural = (n: number, one: string): string => `${n} ${n === 1 ? one : `${one}s`}`

/**
 * The heading. On the way out it counts what is still open, because that is
 * the number somebody has to act on; on the way in, what has been given.
 */
export function accessSummary(rows: ReadonlyArray<{ status: string }>, kind: 'onboarding' | 'offboarding'): string {
  const live = rows.filter((r) => r.status === 'granted').length
  const gone = rows.length - live
  if (kind === 'offboarding') {
    if (!rows.length) return 'Nothing was ever recorded for this person.'
    if (!live) return `All ${plural(gone, 'account')} shut down.`
    return `${plural(live, 'account')} still open${gone ? `, ${gone} already shut down` : ''}.`
  }
  if (!live) return 'What this person has been given. Nothing recorded yet.'
  return `${plural(live, 'account')} recorded${gone ? `, ${gone} since removed` : ''}.`
}

export function friendlyAccessError(message: string): string {
  if (/row-level security/i.test(message)) return 'You cannot change access for this person.'
  if (/schema cache|could not find the function/i.test(message)) {
    return 'This app is newer than the database it is talking to. Tell whoever deploys it.'
  }
  // grant_access / revoke_access raise sentences already written for a person.
  return message
}
