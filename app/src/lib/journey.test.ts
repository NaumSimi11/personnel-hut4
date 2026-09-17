import { describe, expect, it } from 'vitest'
import { JOB_STEPS } from './jobWorkspace'
import { JOURNEY_STEPS, journeyStepIndex, planStep } from './journey'

describe('JOURNEY_STEPS', () => {
  it('carries the hiring steps through to the person actually arriving', () => {
    expect(JOURNEY_STEPS.map((s) => s.id)).toEqual([
      'request',
      'job',
      'publish',
      'applications',
      'hire',
      'onboarding',
      'first_day',
    ])
  })

  it('keeps the hiring steps exactly as the job workspace defines them', () => {
    // The job page and the plan page must agree on the first five, or the
    // strip would appear to renumber itself as you move between them.
    expect(JOURNEY_STEPS.slice(0, JOB_STEPS.length)).toEqual(JOB_STEPS)
  })

  it('numbers the whole arc in order', () => {
    expect(JOURNEY_STEPS.map((s) => s.number)).toEqual(['01', '02', '03', '04', '05', '06', '07'])
  })
})

describe('journeyStepIndex', () => {
  it('places a hiring step where the hiring journey had it', () => {
    expect(journeyStepIndex('request')).toBe(0)
    expect(journeyStepIndex('hire')).toBe(4)
  })

  it('places the steps after the hire', () => {
    expect(journeyStepIndex('onboarding')).toBe(5)
    expect(journeyStepIndex('first_day')).toBe(6)
  })

  it('returns -1 for something it does not know', () => {
    expect(journeyStepIndex('nonsense' as never)).toBe(-1)
  })
})

describe('planStep', () => {
  it('is onboarding while the plan is still being worked before the start', () => {
    expect(planStep({ status: 'in_progress', startDate: '2026-12-01' }, '2026-09-17')).toBe('onboarding')
  })

  it('is the first day once the plan is finished', () => {
    expect(planStep({ status: 'completed', startDate: '2026-12-01' }, '2026-09-17')).toBe('first_day')
  })

  it('is the first day once the start date has arrived, finished or not', () => {
    // They are in the office; unfinished preparation does not undo that.
    expect(planStep({ status: 'in_progress', startDate: '2026-09-17' }, '2026-09-17')).toBe('first_day')
    expect(planStep({ status: 'in_progress', startDate: '2026-09-10' }, '2026-09-17')).toBe('first_day')
  })

  it('treats a cancelled plan as still at the hire, since no one is arriving', () => {
    expect(planStep({ status: 'cancelled', startDate: '2026-09-10' }, '2026-09-17')).toBe('hire')
  })
})
