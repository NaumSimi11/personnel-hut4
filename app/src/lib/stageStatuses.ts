import type { Outcome, SubStatusRow } from '@/lib/hiringLabels'
import type { OutreachEvent, SubStatus } from '@/lib/outreach'

/**
 * Statuses on every stage (plan 068, migration 0088). 0069's sub-statuses
 * lived inside New and Screening only; now every stage may carry its own,
 * an admin adds and retires them from Hiring → Labels, and
 * `set_application_status` sets one at any stage. Pure shaping — the
 * database decides which status fits which stage, and refuses a retired one.
 * The "not responding" rule stays where it was, in outreach.ts.
 *
 * Since plan 075 (migrations 0095/0096) the stages are Zoho's four. Rejected
 * and withdrawn are outcomes of a status, not stages; whether an application
 * is still being worked is `in_play`, never its stage.
 *
 * This file imports no values from other lib modules: dashboard.ts builds on
 * STAGES at load time, so a cycle through here would read it too early.
 */

export const STAGES = ['screening', 'interview', 'offer', 'hired'] as const
export type StageKey = (typeof STAGES)[number]

export const STAGE_LABEL: Record<StageKey, string> = {
  screening: 'Screening',
  interview: 'Interview',
  offer: 'Offered',
  hired: 'Hired',
}

/** The stage filter's pseudo-value (plan 054): open outreach with no activity in 30 days. */
export const NOT_RESPONDING_FILTER = 'not_responding'

const OUTREACH_STAGES = new Set<string>(['screening'])
const LIVE_STAGES: readonly StageKey[] = STAGES.filter((s) => s !== 'hired')
const DO_NOT_CONTACT = 'do_not_contact'
const RETIRED_SUFFIX = ' (retired)'

function stageRank(stageKey: string): number {
  const i = (STAGES as readonly string[]).indexOf(stageKey)
  return i >= 0 ? i : STAGES.length
}

function byStageThenOrder(a: SubStatusRow, b: SubStatusRow): number {
  return stageRank(a.stage_key) - stageRank(b.stage_key) || a.sort_order - b.sort_order || a.key.localeCompare(b.key)
}

function displayLabel(row: SubStatusRow): string {
  return row.archived_at ? `${row.label}${RETIRED_SUFFIX}` : row.label
}

/** Every status by key, retired ones marked, so an application that still carries one reads properly. */
export function statusLabels(rows: ReadonlyArray<SubStatusRow>): Record<string, string> {
  return Object.fromEntries(rows.map((r) => [r.key, displayLabel(r)]))
}

/** The statuses that may be picked: unretired, in stage order then sort order. */
export function liveStatuses(rows: ReadonlyArray<SubStatusRow>): SubStatus[] {
  return rows
    .filter((r) => r.archived_at === null)
    .sort(byStageThenOrder)
    .map(({ key, stage_key, label, sort_order }) => ({ key, stage_key, label, sort_order }))
}

/** The statuses with this outcome that may be picked (Reject and Withdraw pickers): unretired, stage then sort order. */
export function statusesByOutcome(rows: ReadonlyArray<SubStatusRow>, outcome: Outcome): SubStatus[] {
  return liveStatuses(rows.filter((r) => r.outcome === outcome))
}

function labelOfStage(key: string): string {
  return (STAGE_LABEL as Record<string, string>)[key] ?? key
}

export type StatusFilterGroup = { stageKey: string; stageLabel: string; options: { key: string; label: string }[] }

/**
 * The status filter's option groups: one per stage that has any, retired
 * statuses included (an old application can still be found by one), and
 * only the `stageKeys` groups when the list is already narrowed.
 */
export function statusFilterGroups(rows: ReadonlyArray<SubStatusRow>, stageKeys?: ReadonlyArray<string>): StatusFilterGroup[] {
  const sorted = [...rows].filter((r) => !stageKeys || stageKeys.includes(r.stage_key)).sort(byStageThenOrder)
  const stages = [...new Set(sorted.map((r) => r.stage_key))]
  return stages.map((s) => ({
    stageKey: s,
    stageLabel: labelOfStage(s),
    options: sorted.filter((r) => r.stage_key === s).map((r) => ({ key: r.key, label: displayLabel(r) })),
  }))
}

/**
 * The stages whose statuses a stage filter can still show: every stage but
 * Hired for "In progress", Screening for "Not responding", the stage
 * itself for a stage, and every stage (undefined) for "All stages".
 */
export function filterStagesFor(stageFilter: string): readonly string[] | undefined {
  if (stageFilter === 'all') return undefined
  if (stageFilter === 'live') return LIVE_STAGES
  if (stageFilter === NOT_RESPONDING_FILTER) return [...OUTREACH_STAGES]
  return [stageFilter]
}

/**
 * The warning beside "Do not contact": the status labels the application,
 * while the block that stops sourcing and re-applying is the candidate's
 * own contact rule (0067) — a separate, deliberate step.
 */
export function contactHint(key: string): string | null {
  return key === DO_NOT_CONTACT
    ? 'This only labels the application. To stop anyone contacting this person, set Do not contact on their candidate record.'
    : null
}

/** "Status: <from or —> → <to> · <note>", the timeline line of a `status_change` event. */
export function statusChangeLine(event: OutreachEvent, labels: Record<string, string>): string {
  const label = (key: string | null): string => (key ? (labels[key] ?? key) : '—')
  const move = `Status: ${label(event.from_sub_status_key)} → ${label(event.to_sub_status_key)}`
  return event.body ? `${move} · ${event.body}` : move
}

/** What the set-status dialog calls itself: outreach where a status means contact, a status elsewhere. */
export function statusEventTitle(stageKey: string): 'Outreach' | 'Status' {
  return OUTREACH_STAGES.has(stageKey) ? 'Outreach' : 'Status'
}

export function noStatusesHint(stage: string): string {
  return `No statuses at ${stage} yet. An admin adds them under Hiring → Labels.`
}

/** A reject or withdrawal records its reason: the note when written, else the status chosen. */
export function reasonFor(statusLabel: string, note: string): string {
  return note.trim() || statusLabel
}
