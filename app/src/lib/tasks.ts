import { z } from 'zod'
import { todayDb } from '@/lib/compensation'
import { shortDate } from '@/lib/leave'

/**
 * Tasks that stand on their own (plan 057).
 *
 * The database decides who may do what; this is the shaping around it — what
 * a row says on the card, how a list is ordered, and what the form will not
 * send. `my_tasks()` answers with two lists: what I have to do (mine, plus
 * anything I am connected to) and what I have handed out.
 */

export type TaskPerson = { id: string; full_name: string }

export type MyTask = {
  id: string
  person_id: string
  title: string
  detail: string | null
  due_date: string | null
  status: 'open' | 'done'
  created_by: string
  created_at: string
  done_at: string | null
  person_name: string
  created_by_name: string
  done_by_name: string | null
  with_people: TaskPerson[]
  is_mine: boolean
}

/** A task I set for somebody else — the shorter shape `my_tasks()` returns. */
export type TaskISet = {
  id: string
  person_id: string
  title: string
  detail: string | null
  due_date: string | null
  status: 'open' | 'done'
  done_at: string | null
  created_at: string
  person_name: string
}

export type MyTasks = { mine: MyTask[]; set_by_me: TaskISet[] }

export const EMPTY_TASKS: MyTasks = { mine: [], set_by_me: [] }

// ------------------------------------------------------------------ input

/**
 * What the dialog may send. The same limits the database enforces, checked
 * here so a typo is answered in the form rather than by a round trip — and
 * so a note of 2,001 characters is never silently truncated on the way.
 */
export const taskInput = z.object({
  id: z.string().uuid().optional(),
  person_id: z.string().uuid().optional(),
  title: z.string().trim().min(1, 'Give the task a title.').max(200, 'Keep the title to 200 characters or fewer.'),
  detail: z.string().trim().max(2000, 'Keep the note to 2,000 characters or fewer.').optional(),
  due_date: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/, 'Give the date as a calendar date.')
    .optional(),
  with_ids: z.array(z.string().uuid()).optional(),
})

export type TaskInput = z.infer<typeof taskInput>

// ----------------------------------------------------------------- reading

/** `my_tasks()` returns JSON; nothing else in the app may assume its shape. */
export function readMyTasks(data: unknown): MyTasks {
  const raw = (data ?? {}) as Partial<MyTasks>
  return {
    mine: Array.isArray(raw.mine) ? raw.mine : [],
    set_by_me: Array.isArray(raw.set_by_me) ? raw.set_by_me : [],
  }
}

export type DueTone = 'overdue' | 'today' | 'soon' | 'later' | 'none'

/** How a due date reads today: the same words on the card and in the count. */
export function dueTone(task: { due_date: string | null; status: string }, today = todayDb()): DueTone {
  if (task.status === 'done' || !task.due_date) return 'none'
  if (task.due_date < today) return 'overdue'
  if (task.due_date === today) return 'today'
  // "Soon" is the working week ahead — far enough to plan, near enough to
  // matter. A date beyond it is just a date.
  const soon = new Date(`${today}T00:00:00Z`)
  soon.setUTCDate(soon.getUTCDate() + 7)
  return task.due_date <= soon.toISOString().slice(0, 10) ? 'soon' : 'later'
}

export function dueLabel(task: { due_date: string | null; status: string }, today = todayDb()): string | null {
  if (!task.due_date) return null
  const tone = dueTone(task, today)
  if (tone === 'overdue') return `overdue · ${shortDate(task.due_date)}`
  if (tone === 'today') return 'due today'
  return `due ${shortDate(task.due_date)}`
}

/**
 * Open first, then by when it is due — a task with no date after the dated
 * ones, because a date is a promise and no date is not. Done tasks keep the
 * order they were finished in, newest last, so a list does not reshuffle
 * under the hand that ticked it.
 */
export function orderTasks<T extends { status: string; due_date: string | null; created_at: string }>(
  tasks: ReadonlyArray<T>,
): T[] {
  return [...tasks].sort((a, b) => {
    if (a.status !== b.status) return a.status === 'open' ? -1 : 1
    if (a.due_date !== b.due_date) {
      if (!a.due_date) return 1
      if (!b.due_date) return -1
      return a.due_date < b.due_date ? -1 : 1
    }
    return a.created_at < b.created_at ? -1 : 1
  })
}

/** What the card's heading says, so the number and the list never disagree. */
export function openCount(tasks: ReadonlyArray<{ status: string }>): number {
  return tasks.filter((t) => t.status === 'open').length
}

/** Whose task this is, in words, when it is not mine. */
export function ownerLine(task: MyTask): string | null {
  if (task.is_mine) return null
  return `${task.person_name}'s task`
}

/** "with Ana Kova and Ben Ilić" — the colleagues on it, or nothing. */
export function withLine(task: Pick<MyTask, 'with_people'>): string | null {
  const names = task.with_people.map((p) => p.full_name)
  if (!names.length) return null
  if (names.length === 1) return `with ${names[0]}`
  if (names.length === 2) return `with ${names[0]} and ${names[1]}`
  return `with ${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`
}

/** The database's refusals reach the card as they were written; the rest is translated. */
export function friendlyTaskError(message: string): string {
  if (/row-level security/i.test(message)) return 'That task is not yours to change.'
  if (/jwt|not authenticated/i.test(message)) return 'Your session expired. Sign in again.'
  return message
}
