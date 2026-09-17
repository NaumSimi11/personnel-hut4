import { progress, type ChecklistKind, type ChecklistTask } from './checklists'

/**
 * The one line above a checklist queue.
 *
 * The queue is where HR works, but the top of the page carried nothing: you had
 * to read every row and add it up yourself to learn how much was outstanding.
 * This states the total — how many plans are running, how much is still missing,
 * and who arrives (or leaves) within the week.
 */
export type QueueSummary = {
  readonly plans: number
  readonly gaps: number
  readonly startingSoon: number
}

export type QueuePlan = {
  readonly start_date: string
  readonly plan_tasks: ChecklistTask[]
}

const DAY_MS = 24 * 60 * 60 * 1000
const WINDOW_DAYS = 7

export function queueSummary(plans: readonly QueuePlan[], today: string): QueueSummary {
  const horizon = Date.parse(today) + WINDOW_DAYS * DAY_MS
  return {
    plans: plans.length,
    gaps: plans.reduce((sum, p) => sum + progress(p.plan_tasks).criticalOpen, 0),
    // A start date already past still counts: they are late, not absent.
    startingSoon: plans.filter((p) => Date.parse(p.start_date) <= horizon).length,
  }
}

function count(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`
}

export function queueSummaryLine(summary: QueueSummary, kind: ChecklistKind): string | null {
  if (summary.plans === 0) return null
  const leaving = kind === 'offboarding'
  const parts = [`${summary.plans} in progress`]

  if (summary.gaps > 0) {
    parts.push(
      leaving
        ? count(summary.gaps, 'blocker', 'blockers')
        : `${summary.gaps} readiness ${summary.gaps === 1 ? 'gap' : 'gaps'}`,
    )
  }
  if (summary.startingSoon > 0) {
    parts.push(`${summary.startingSoon} ${leaving ? 'leaving' : 'starting'} this week`)
  }
  return parts.join(' · ')
}
