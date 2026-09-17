import { z } from 'zod'

/**
 * Checklists (plan 047): one person's onboarding or offboarding plan worked
 * as a checkbox list, and the per-company templates it starts from. The
 * database (migration 0040) decides every rule; these helpers shape what
 * is shown and put the refusals into words.
 */

export type ChecklistKind = 'onboarding' | 'offboarding'

export type ChecklistTask = {
  id: string
  title: string
  owner_role: string
  phase_key: string
  due_date: string | null
  critical: boolean
  status: string
  blocked_reason: string | null
  skip_reason: string | null
  done_at: string | null
  owner: { full_name: string } | null
}

export type Phase = { key: string; label: string; sort_order: number }

export const OWNER_ROLES = [
  { key: 'hr', label: 'HR' },
  { key: 'it', label: 'IT' },
  { key: 'manager', label: 'Manager' },
  { key: 'employee', label: 'The person' },
  { key: 'finance', label: 'Finance' },
] as const

export const PHASES_FOR: Record<ChecklistKind, string[]> = {
  onboarding: ['before_start', 'day_one', 'week_one', 'month_one'],
  offboarding: ['before_last_day', 'last_day', 'after_departure'],
}

export function ownerLabel(role: string): string {
  return OWNER_ROLES.find((o) => o.key === role)?.label ?? role
}

export type Progress = { closed: number; total: number; percent: number; criticalOpen: number }

const CLOSED = new Set(['done', 'skipped'])

export function progress(tasks: ChecklistTask[]): Progress {
  const total = tasks.length
  const closed = tasks.filter((t) => CLOSED.has(t.status)).length
  const criticalOpen = tasks.filter((t) => t.critical && !CLOSED.has(t.status)).length
  return { closed, total, percent: total ? Math.round((closed / total) * 100) : 0, criticalOpen }
}

export function groupByPhase<T extends { phase_key: string }>(phases: Phase[], tasks: T[]): (Phase & { tasks: T[] })[] {
  return [...phases]
    .sort((a, b) => a.sort_order - b.sort_order)
    .map((p) => ({ ...p, tasks: tasks.filter((t) => t.phase_key === p.key) }))
    .filter((p) => p.tasks.length > 0)
}

/** "3 days before the start", "On the last day" — a line's timing in words. */
export function whenLabel(phaseKey: string, offset: number, kind: ChecklistKind): string {
  const anchor = kind === 'onboarding' ? 'the start' : 'the last day'
  if (offset === 0) return phaseKey === 'day_one' || phaseKey === 'last_day' ? (kind === 'onboarding' ? 'On the first day' : 'On the last day') : `On ${anchor}`
  const n = Math.abs(offset)
  const days = `${n} ${n === 1 ? 'day' : 'days'}`
  return offset < 0 ? `${days} before ${anchor}` : `${days} after ${anchor}`
}

export type TemplateLineForm = {
  title: string
  description: string
  ownerRole: string
  phaseKey: string
  dueOffsetDays: number
  critical: boolean
  requiresEvidence: boolean
}

export function emptyTemplateLine(kind: ChecklistKind): TemplateLineForm {
  return {
    title: '',
    description: '',
    ownerRole: 'hr',
    phaseKey: PHASES_FOR[kind][0] as string,
    dueOffsetDays: -1,
    critical: false,
    requiresEvidence: false,
  }
}

export function lineInput(kind: ChecklistKind) {
  return z.object({
    title: z.string().trim().min(2, 'Enter what has to be done.').max(160),
    description: z.string().trim().max(500),
    ownerRole: z.enum(['hr', 'it', 'manager', 'employee', 'finance']),
    phaseKey: z.string().refine((k) => PHASES_FOR[kind].includes(k), 'Choose when it is due.'),
    dueOffsetDays: z.number().int().min(-60, 'At most 60 days before.').max(120, 'At most 120 days after.'),
    critical: z.boolean(),
    requiresEvidence: z.boolean(),
  })
}

/** The id order after moving one line up (-1) or down (+1); unchanged at the edges. */
export function moved(ids: string[], id: string, direction: -1 | 1): string[] {
  const i = ids.indexOf(id)
  const j = i + direction
  if (i < 0 || j < 0 || j >= ids.length) return ids
  const next = [...ids]
  next[i] = ids[j] as string
  next[j] = ids[i] as string
  return next
}

export type QueueFilter = { companyId: string; ownerRole: string }

/** Plans in the company, and — when an owner is chosen — with something still open for that owner. */
export function filterPlans<T extends { company_id: string; plan_tasks: { owner_role: string; status: string }[] }>(plans: T[], f: QueueFilter): T[] {
  return plans.filter(
    (p) =>
      (!f.companyId || p.company_id === f.companyId) &&
      (!f.ownerRole || p.plan_tasks.some((t) => t.owner_role === f.ownerRole && !CLOSED.has(t.status))),
  )
}

export function messageForChecklist(error: { code?: string; message: string }): string {
  if (error.code === '42501') return `${error.message} Ask for the grant if this is your job.`
  if (/row-level security/i.test(error.message)) return 'You do not have permission to change this checklist.'
  return error.message
}

/**
 * The line under a person's name in a checklist queue.
 *
 * It carries the role because a queue keyed only on name, company and date
 * renders two different hires identically when they happen to share a name —
 * and picking the wrong one means onboarding, or handing a laptop to, the
 * wrong human.
 */
export type PlanSummary = {
  readonly companyName: string | null
  readonly jobTitle: string | null
  readonly startDate: string
  readonly endDate: string | null
  readonly closed: number
  readonly total: number
}

export function planMeta(plan: PlanSummary, kind: ChecklistKind): string {
  const leaving = kind === 'offboarding'
  const parts = [plan.companyName ?? '—']
  if (plan.jobTitle) parts.push(plan.jobTitle)
  parts.push(`${leaving ? 'last day' : 'starts'} ${plan.startDate}`)
  if (leaving && plan.endDate && plan.endDate !== plan.startDate) {
    parts.push(`employment ends ${plan.endDate}`)
  }
  parts.push(`${plan.closed}/${plan.total} done`)
  return parts.join(' · ')
}
