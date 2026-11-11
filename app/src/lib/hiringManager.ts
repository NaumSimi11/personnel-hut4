import type { SubStatusRow } from '@/lib/hiringLabels'

/**
 * The hiring manager's panel on an application (0100): the three HM statuses
 * at Screening, and why not elsewhere. Mirrors `hm_set_status`, which is the
 * rule; this only decides what to show.
 */
export type HmChoice = { key: string; label: string; current: boolean }

export type HmPanel =
  | { mode: 'hidden' }
  | { mode: 'decide'; choices: HmChoice[] }
  | { mode: 'locked'; reason: string; current: string | null }

export type HmApplication = {
  stage_key: string
  sub_status_key: string | null
  closed_at: string | null
  job_status: string
}

const CLOSED_JOB = new Set(['closed', 'filled'])

/** The live HM statuses, in the order HR sorted them. */
export function hmStatuses(rows: readonly SubStatusRow[]): SubStatusRow[] {
  return rows.filter((r) => r.hm_only && !r.archived_at).sort((a, b) => a.sort_order - b.sort_order)
}

export function hmPanel(app: HmApplication, rows: readonly SubStatusRow[], isHiringManager: boolean): HmPanel {
  if (!isHiringManager) return { mode: 'hidden' }
  const byKey = new Map(rows.map((r) => [r.key, r]))
  const current = app.sub_status_key ? (byKey.get(app.sub_status_key) ?? null) : null
  const currentLabel = current?.label ?? app.sub_status_key
  if (app.closed_at || CLOSED_JOB.has(app.job_status)) {
    return { mode: 'locked', reason: 'This job is closed. Nothing more to decide here.', current: currentLabel }
  }
  if (app.stage_key === 'offer') {
    return { mode: 'locked', reason: 'At Offer — HR is preparing the offer. You can follow it here.', current: currentLabel }
  }
  if (app.stage_key !== 'screening') {
    return { mode: 'locked', reason: 'Past screening — HR takes it from here.', current: currentLabel }
  }
  if (current && current.outcome !== 'open' && !current.hm_only) {
    return { mode: 'locked', reason: `HR closed this at screening (${current.label}). HR reopens it first.`, current: currentLabel }
  }
  const choices = hmStatuses(rows).map((r) => ({ key: r.key, label: r.label, current: r.key === app.sub_status_key }))
  return { mode: 'decide', choices }
}
