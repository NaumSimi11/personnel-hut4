import { describe, expect, it } from 'vitest'
import type { ChecklistTask } from './checklists'
import { queueSummary, queueSummaryLine } from './queueSummary'

const TODAY = '2026-09-17'

function line(over: Partial<ChecklistTask> = {}): ChecklistTask {
  return {
    id: 'x',
    title: 'x',
    owner_role: 'hr',
    phase_key: 'before_start',
    due_date: null,
    critical: false,
    status: 'open',
    blocked_reason: null,
    skip_reason: null,
    done_at: null,
    owner: null,
    ...over,
  }
}
const gap = () => line({ critical: true, status: 'open' })
const settled = () => line({ critical: true, status: 'done' })

describe('queueSummary', () => {
  it('counts nothing for an empty queue', () => {
    expect(queueSummary([], TODAY)).toEqual({ plans: 0, gaps: 0, startingSoon: 0 })
  })

  it('counts the plans it was given', () => {
    const plans = [
      { start_date: '2026-12-01', plan_tasks: [] },
      { start_date: '2026-12-02', plan_tasks: [] },
    ]
    expect(queueSummary(plans, TODAY).plans).toBe(2)
  })

  it('adds up the required lines still open across everyone', () => {
    const plans = [
      { start_date: '2026-12-01', plan_tasks: [gap(), gap(), settled()] },
      { start_date: '2026-12-02', plan_tasks: [gap()] },
    ]
    expect(queueSummary(plans, TODAY).gaps).toBe(3)
  })

  it('counts who arrives within the week ahead, including today', () => {
    const plans = [
      { start_date: '2026-09-17', plan_tasks: [] }, // today
      { start_date: '2026-09-24', plan_tasks: [] }, // the last day of the window
      { start_date: '2026-09-25', plan_tasks: [] }, // just outside
      { start_date: '2026-12-01', plan_tasks: [] },
    ]
    expect(queueSummary(plans, TODAY).startingSoon).toBe(2)
  })

  it('still counts someone whose start date has already passed', () => {
    // They are late, not absent — leaving them out would hide the worst case.
    expect(queueSummary([{ start_date: '2026-09-10', plan_tasks: [] }], TODAY).startingSoon).toBe(1)
  })
})

describe('queueSummaryLine', () => {
  it('says nothing at all when the queue is empty', () => {
    expect(queueSummaryLine({ plans: 0, gaps: 0, startingSoon: 0 }, 'onboarding')).toBeNull()
  })

  it('reads as one sentence for a joining queue', () => {
    expect(queueSummaryLine({ plans: 3, gaps: 13, startingSoon: 1 }, 'onboarding')).toBe(
      '3 in progress · 13 readiness gaps · 1 starting this week',
    )
  })

  it('uses the language of leaving for the other queue', () => {
    expect(queueSummaryLine({ plans: 2, gaps: 4, startingSoon: 1 }, 'offboarding')).toBe(
      '2 in progress · 4 blockers · 1 leaving this week',
    )
  })

  it('leaves out the parts that would read as zero', () => {
    expect(queueSummaryLine({ plans: 2, gaps: 0, startingSoon: 0 }, 'onboarding')).toBe('2 in progress')
  })

  it('counts in the singular where it should', () => {
    expect(queueSummaryLine({ plans: 1, gaps: 1, startingSoon: 1 }, 'onboarding')).toBe(
      '1 in progress · 1 readiness gap · 1 starting this week',
    )
  })
})
