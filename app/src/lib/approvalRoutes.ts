/**
 * Editing a company's approval route (0104). A step is a label plus either a
 * named person or a capability ("anyone holding it"). With no steps saved,
 * the company uses the built-in default, shown so people know what applies.
 */
export type RouteKind = 'request' | 'offer_in_band' | 'offer_out_of_band'
export type StepDraft = { label: string; approverId: string; capability: string }

export const ROUTE_KINDS: ReadonlyArray<{ value: RouteKind; label: string }> = [
  { value: 'request', label: 'Hiring requests' },
  { value: 'offer_in_band', label: 'Offers inside the salary band' },
  { value: 'offer_out_of_band', label: 'Offers outside the band (or no band match)' },
]

export const STEP_CAPABILITIES: ReadonlyArray<{ value: string; label: string }> = [
  { value: 'jobs.approve', label: 'Anyone who approves hiring requests' },
  { value: 'offer.approve', label: 'Anyone who approves offers (HR)' },
  { value: 'salary.view', label: 'Anyone who sees salaries (Finance)' },
  { value: 'payroll.approve', label: 'Anyone who approves payroll' },
  { value: 'candidates.review', label: 'Anyone who records interview feedback' },
]

export const DEFAULT_ROUTE: Record<RouteKind, string> = {
  request: '1. Hiring approver (anyone who approves hiring requests)',
  offer_in_band: '1. HR (anyone who approves offers)',
  offer_out_of_band: '1. HR · 2. Finance (anyone who sees salaries) · 3. The company director',
}

export const MAX_STEPS = 6

/** The rows to save, or the first problem. Steps are numbered in order. */
export function routeRows(companyId: string, kind: RouteKind, steps: readonly StepDraft[]):
  | { rows: { company_id: string; kind: RouteKind; position: number; label: string; approver_id: string | null; capability: string | null }[]; error: null }
  | { rows: null; error: string } {
  if (steps.length > MAX_STEPS) return { rows: null, error: `Keep the route to ${MAX_STEPS} steps or fewer.` }
  for (const [i, s] of steps.entries()) {
    if (!s.label.trim()) return { rows: null, error: `Name step ${i + 1}.` }
    if (s.label.trim().length > 80) return { rows: null, error: `Keep step ${i + 1}'s name short.` }
    // A named person wins over a group left selected from before.
    if (!s.approverId && !s.capability) return { rows: null, error: `Step ${i + 1}: pick a person or a group.` }
  }
  return {
    rows: steps.map((s, i) => ({
      company_id: companyId,
      kind,
      position: i + 1,
      label: s.label.trim(),
      approver_id: s.approverId || null,
      capability: s.approverId ? null : s.capability,
    })),
    error: null,
  }
}

export function moveStep(steps: readonly StepDraft[], from: number, by: -1 | 1): StepDraft[] {
  const to = from + by
  if (to < 0 || to >= steps.length) return [...steps]
  const next = [...steps]
  ;[next[from], next[to]] = [next[to], next[from]]
  return next
}
