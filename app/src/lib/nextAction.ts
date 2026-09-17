import { PHASES_FOR, ownerLabel, type ChecklistKind, type ChecklistTask } from './checklists'

/**
 * The one line to put in front of whoever opens a checklist.
 *
 * A plan shows every line at equal weight, which leaves the reader to work out
 * what to do first from eleven checkboxes, some overdue, some not yet relevant.
 * They already know the answer; this states it.
 *
 * The order is: blocked before anything else (it cannot move without help),
 * then required before optional, then whatever is due soonest, and finally the
 * order the phases themselves run in.
 */
export type NextAction = {
  readonly task: ChecklistTask
  /** Days until the due date; negative when past, null when there is none. */
  readonly days: number | null
  readonly overdue: boolean
}

const CLOSED = new Set(['done', 'skipped'])
const DAY_MS = 24 * 60 * 60 * 1000

function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(to) - Date.parse(from)) / DAY_MS)
}

function rank(task: ChecklistTask, phaseOrder: readonly string[]): readonly number[] {
  const phase = phaseOrder.indexOf(task.phase_key)
  return [
    task.status === 'blocked' ? 0 : 1,
    task.critical ? 0 : 1,
    task.due_date ? 0 : 1,
    task.due_date ? Date.parse(task.due_date) : 0,
    phase === -1 ? phaseOrder.length : phase,
  ]
}

function comesFirst(a: readonly number[], b: readonly number[]): boolean {
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return (a[i] ?? 0) < (b[i] ?? 0)
  }
  return false
}

export function nextAction(
  tasks: readonly ChecklistTask[],
  kind: ChecklistKind,
  today: string,
): NextAction | null {
  const phaseOrder = PHASES_FOR[kind]
  const open = tasks.filter((t) => !CLOSED.has(t.status))
  if (open.length === 0) return null

  const chosen = open.reduce((best, task) =>
    comesFirst(rank(task, phaseOrder), rank(best, phaseOrder)) ? task : best,
  )
  const days = chosen.due_date ? daysBetween(today, chosen.due_date) : null
  return { task: chosen, days, overdue: days !== null && days < 0 }
}

function countOfDays(n: number): string {
  return n === 1 ? '1 day' : `${n} days`
}

/** The next action as one line of plain English. */
export function nextActionSentence(next: NextAction): string {
  const { task, days } = next
  if (task.status === 'blocked') {
    const why = task.blocked_reason?.trim()
    return why ? `${task.title} is blocked — ${why}` : `${task.title} is blocked`
  }
  const who = `${task.title} — ${ownerLabel(task.owner_role)}`
  if (days === null) return who
  if (days < 0) return `${who}, ${countOfDays(-days)} overdue`
  if (days === 0) return `${who}, due today`
  if (days === 1) return `${who}, due tomorrow`
  return `${who}, due in ${countOfDays(days)}`
}
