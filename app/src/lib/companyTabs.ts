/**
 * Which tabs a company profile shows (task.md, maintainer review).
 *
 * Two tabs are deferred rather than deleted: Equipment duplicates the
 * holding-wide Equipment page in the sidebar, and Projects fronts the Zoho
 * Projects mirror, which stays dormant until the credentials arrive
 * (development-plan.md "Next", item 1). Structure is kept on the holding
 * only — the group's shape is one thing, not six.
 *
 * Restoring any of them is deleting a line here. The rest is capability
 * gating, which the panels and RLS enforce again on their own.
 */

export type TabContext = {
  isAdmin: boolean
  can: (capability: string) => boolean
  /** `companies.kind`; 'holding' is the group parent (Hut4), 'company' a subsidiary. */
  companyKind: string
}

/** Hidden everywhere, for everyone, until the maintainer asks for them back. */
export const DEFERRED_TABS = ['equipment', 'projects'] as const

/** Settings is shaped by these, beyond admins. */
const SETTINGS_CAPABILITIES = ['tasks.assign', 'it.assign', 'payroll.individual']
/** Activity is readable by any of these. */
const ACTIVITY_CAPABILITIES = ['access.manage', 'jobs.view', 'candidates.view']

export function isTabVisible(id: string, ctx: TabContext): boolean {
  if ((DEFERRED_TABS as readonly string[]).includes(id)) return false
  if (id === 'structure') return ctx.companyKind === 'holding'
  if (id === 'payroll') return ctx.can('payroll.summary')
  if (id === 'settings') return ctx.isAdmin || SETTINGS_CAPABILITIES.some((c) => ctx.can(c))
  if (id === 'activity') return ACTIVITY_CAPABILITIES.some((c) => ctx.can(c))
  return true
}

export function visibleCompanyTabs<T extends { id: string }>(tabs: ReadonlyArray<T>, ctx: TabContext): T[] {
  return tabs.filter((t) => isTabVisible(t.id, ctx))
}
