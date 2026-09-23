import type { ChecklistKind } from './checklists'

/**
 * Which sections a plan page actually shows, in the order they appear.
 *
 * The page runs to a couple of thousand pixels — checklist, welcome note,
 * starter kit, handover — with no way to reach the bottom half but scrolling.
 * A nav fixes that, but only if it lists the sections that are really there:
 * the ones a viewer lacks the capability for, or that do not apply to someone
 * leaving, must not appear as links to nowhere.
 *
 * Tabs were the other option and were rejected. The handover shows red
 * *because* a checklist line is unfilled, so hiding one to read the other
 * would cost more than the scrolling does.
 */
export type PlanSectionId = 'checklist' | 'welcome' | 'kit' | 'access' | 'handover'

export type PlanSection = {
  readonly id: PlanSectionId
  readonly label: string
}

export type PlanVisibility = {
  readonly kind: ChecklistKind
  readonly hasPerson: boolean
  readonly canViewTasks: boolean
  readonly canViewIt: boolean
}

export function planSections(plan: PlanVisibility): PlanSection[] {
  const joining = plan.kind === 'onboarding'
  const sections: PlanSection[] = [{ id: 'checklist', label: 'Checklist' }]

  if (joining && plan.canViewTasks) {
    sections.push({ id: 'welcome', label: 'Welcome note' })
  }
  if (joining && plan.hasPerson && plan.canViewIt) {
    sections.push({ id: 'kit', label: 'Starter kit' })
  }
  // Access shows on both kinds (plan 061): on the way out it is the list of
  // what is still open, which is the question the last day asks.
  //
  // `tasks.view`, like the handover, because that is who can open this page at
  // all — `plans` admits the person themselves or a tasks.view holder (0006).
  // The database lets a person's manager keep their access list, but a manager
  // holding nothing else cannot reach this page to do it; making that real
  // needs the plans policy widened, which is a decision of its own.
  if (plan.hasPerson && plan.canViewTasks) {
    sections.push({ id: 'access', label: joining ? 'Access' : 'Access to shut down' })
  }
  if (plan.hasPerson && plan.canViewTasks) {
    sections.push({ id: 'handover', label: 'Handover' })
  }
  return sections
}
