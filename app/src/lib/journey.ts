import { JOB_STEPS, type StepId } from './jobWorkspace'

/**
 * The whole arc, from opening a position to the person being in the office.
 *
 * Hiring already had a five-step strip on the job page, and it was the clearest
 * navigation in the app — but it stopped at "Hired", which is precisely where
 * the handoff to onboarding happens and where the thread was easiest to lose.
 * Continuing the same strip onto the plan page makes the two halves read as one
 * journey rather than two tools.
 *
 * `JOB_STEPS` stays exactly as it is: the job workspace's own contract, and the
 * first five entries here, so the numbering never shifts between the pages.
 */
export type JourneyStepId = StepId | 'onboarding' | 'first_day'

export type JourneyStep = {
  readonly id: JourneyStepId
  readonly number: string
  readonly label: string
}

export const JOURNEY_STEPS: readonly JourneyStep[] = [
  ...JOB_STEPS,
  { id: 'onboarding', number: '06', label: 'Onboarding' },
  { id: 'first_day', number: '07', label: 'First day' },
]

export function journeyStepIndex(step: JourneyStepId): number {
  return JOURNEY_STEPS.findIndex((s) => s.id === step)
}

export type PlanProgress = {
  readonly status: string
  readonly startDate: string
}

/** Where a person's onboarding plan sits on the arc. */
export function planStep(plan: PlanProgress, today: string): JourneyStepId {
  // A cancelled plan means nobody is arriving, so the journey rests at the hire.
  if (plan.status === 'cancelled') return 'hire'
  if (plan.status === 'completed') return 'first_day'
  return plan.startDate <= today ? 'first_day' : 'onboarding'
}
