/**
 * What is missing for the app to work (plan 073, migration 0093). setup_gaps
 * returns, for the companies the viewer looks after, the workflow owners and
 * inboxes still unset; this turns that into the Overview banner's lines —
 * the roles that leave work with nobody first, the inboxes after.
 */

export type SetupGaps = {
  can_fix: boolean
  companies: { company_id: string; company_name: string; missing_roles: string[]; missing_inboxes: string[] }[]
}

export type GapLine = {
  key: 'it_owner' | 'hr_owner' | 'inboxes'
  /** True when work goes to nobody; false when it only goes to the wrong address. */
  strong: boolean
  title: string
  consequence: string
  companies: { id: string; name: string; detail: string | null }[]
}

const ROLE_LINES = [
  { key: 'it_owner', title: 'No IT owner', consequence: 'Onboarding IT lines and new IT requests reach nobody.' },
  { key: 'hr_owner', title: 'No HR owner', consequence: 'Nobody is told when an IT request is blocked.' },
] as const

function inboxWords(missing: string[]): string {
  const it = missing.includes('it')
  const hr = missing.includes('hr')
  return it && hr ? 'IT and HR' : it ? 'IT' : 'HR'
}

export function gapLines(gaps: SetupGaps): GapLine[] {
  const roles: GapLine[] = ROLE_LINES.map((r) => ({
    key: r.key,
    strong: true,
    title: r.title,
    consequence: r.consequence,
    companies: gaps.companies
      .filter((c) => c.missing_roles.includes(r.key))
      .map((c) => ({ id: c.company_id, name: c.company_name, detail: null })),
  }))
  const inboxes: GapLine = {
    key: 'inboxes',
    strong: false,
    title: 'No IT or HR inbox',
    consequence: "Those emails go to the owner's own address instead.",
    companies: gaps.companies
      .filter((c) => c.missing_inboxes.length > 0)
      .map((c) => ({ id: c.company_id, name: c.company_name, detail: inboxWords(c.missing_inboxes) })),
  }
  return [...roles, inboxes].filter((l) => l.companies.length > 0)
}
