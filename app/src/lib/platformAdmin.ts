/**
 * Platform admins: full access to every company and every page (blueprint
 * §3). Granting and removing is done from the access editor by another
 * admin; the database keeps the last admin in place (`keep_last_admin`),
 * and the UI never offers you the button to remove yourself — lock-outs
 * are a second person's mistake to make, deliberately.
 */
export type PlatformAdminControl = {
  action: 'grant' | 'revoke'
  label: string
  disabled: boolean
  reason: string | null
}

export function platformAdminControl(input: { isAdmin: boolean; isSelf: boolean; admins: number }): PlatformAdminControl {
  if (!input.isAdmin) return { action: 'grant', label: 'Make platform admin', disabled: false, reason: null }
  if (input.isSelf) return { action: 'revoke', label: 'Remove platform admin', disabled: true, reason: 'Ask another platform admin to remove you.' }
  if (input.admins <= 1) return { action: 'revoke', label: 'Remove platform admin', disabled: true, reason: 'The last platform admin cannot be removed.' }
  return { action: 'revoke', label: 'Remove platform admin', disabled: false, reason: null }
}
