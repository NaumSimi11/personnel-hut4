import { describe, expect, it } from 'vitest'
import type { ChecklistTask } from './checklists'
import { nextAction, nextActionSentence } from './nextAction'

const TODAY = '2026-09-17'

function task(over: Partial<ChecklistTask> & { title: string }): ChecklistTask {
  return {
    id: over.title,
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

describe('nextAction', () => {
  it('is nothing at all when every line is closed', () => {
    const done = [
      task({ title: 'Agreement signed', status: 'done' }),
      task({ title: 'Kit issued', status: 'skipped' }),
    ]
    expect(nextAction(done, 'onboarding', TODAY)).toBeNull()
  })

  it('picks a required line over a merely earlier one', () => {
    const tasks = [
      task({ title: 'Team introduction', due_date: '2026-09-18' }),
      task({ title: 'Bank details collected', due_date: '2026-09-25', critical: true }),
    ]
    expect(nextAction(tasks, 'onboarding', TODAY)?.task.title).toBe('Bank details collected')
  })

  it('among required lines takes the one due soonest', () => {
    const tasks = [
      task({ title: 'Work account created', due_date: '2026-09-20', critical: true }),
      task({ title: 'Agreement signed', due_date: '2026-09-14', critical: true }),
    ]
    expect(nextAction(tasks, 'onboarding', TODAY)?.task.title).toBe('Agreement signed')
  })

  it('reports how late a line already is', () => {
    const tasks = [task({ title: 'Agreement signed', due_date: '2026-09-14', critical: true })]
    const next = nextAction(tasks, 'onboarding', TODAY)
    expect(next?.overdue).toBe(true)
    expect(next?.days).toBe(-3)
  })

  it('reports how long is left on a line not yet due', () => {
    const tasks = [task({ title: 'First 1:1', due_date: '2026-09-19' })]
    const next = nextAction(tasks, 'onboarding', TODAY)
    expect(next?.overdue).toBe(false)
    expect(next?.days).toBe(2)
  })

  it('treats a line with no due date as neither due nor late', () => {
    const next = nextAction([task({ title: 'Team introduction' })], 'onboarding', TODAY)
    expect(next?.days).toBeNull()
    expect(next?.overdue).toBe(false)
  })

  it('falls back to the order of the phases when nothing else separates them', () => {
    const tasks = [
      task({ title: 'First 1:1', phase_key: 'week_one' }),
      task({ title: 'Team introduction', phase_key: 'day_one' }),
      task({ title: 'Agreement signed', phase_key: 'before_start' }),
    ]
    expect(nextAction(tasks, 'onboarding', TODAY)?.task.title).toBe('Agreement signed')
  })

  it('surfaces a blocked line ahead of work that is merely waiting', () => {
    // A blocked line cannot move on its own — someone has to intervene, so it
    // is the more useful thing to put in front of whoever opens the plan.
    const tasks = [
      task({ title: 'Agreement signed', due_date: '2026-09-14', critical: true }),
      task({ title: 'Work account created', status: 'blocked', blocked_reason: 'No licence' }),
    ]
    expect(nextAction(tasks, 'onboarding', TODAY)?.task.title).toBe('Work account created')
  })

  it('never returns a closed line even when it is the most urgent', () => {
    const tasks = [
      task({ title: 'Agreement signed', due_date: '2026-01-01', critical: true, status: 'done' }),
      task({ title: 'Team introduction', due_date: '2026-12-01' }),
    ]
    expect(nextAction(tasks, 'onboarding', TODAY)?.task.title).toBe('Team introduction')
  })

  it('orders an offboarding plan by its own phases', () => {
    const tasks = [
      task({ title: 'Access revoked', phase_key: 'after_departure' }),
      task({ title: 'Equipment returned', phase_key: 'before_last_day' }),
    ]
    expect(nextAction(tasks, 'offboarding', TODAY)?.task.title).toBe('Equipment returned')
  })
})

describe('nextActionSentence', () => {
  const of = (t: Partial<ChecklistTask> & { title: string }, days: number | null) => ({
    task: task(t),
    days,
    overdue: days !== null && days < 0,
  })

  it('says who owes a line that is not yet due', () => {
    expect(nextActionSentence(of({ title: 'First 1:1', owner_role: 'manager' }, 2)))
      .toBe('First 1:1 — Manager, due in 2 days')
  })

  it('says "due today" rather than "in 0 days"', () => {
    expect(nextActionSentence(of({ title: 'Team introduction', owner_role: 'manager' }, 0)))
      .toBe('Team introduction — Manager, due today')
  })

  it('counts the days a line is already late', () => {
    expect(nextActionSentence(of({ title: 'Agreement signed', owner_role: 'hr' }, -3)))
      .toBe('Agreement signed — HR, 3 days overdue')
  })

  it('reads naturally for a single day', () => {
    expect(nextActionSentence(of({ title: 'Agreement signed', owner_role: 'hr' }, -1)))
      .toBe('Agreement signed — HR, 1 day overdue')
    expect(nextActionSentence(of({ title: 'First 1:1', owner_role: 'hr' }, 1)))
      .toBe('First 1:1 — HR, due tomorrow')
  })

  it('leads with the blockage when a line is stuck', () => {
    expect(
      nextActionSentence(
        of({ title: 'Work account created', owner_role: 'it', status: 'blocked', blocked_reason: 'No licence' }, -1),
      ),
    ).toBe('Work account created is blocked — No licence')
  })

  it('says only what it knows when there is no due date', () => {
    expect(nextActionSentence(of({ title: 'Team introduction', owner_role: 'manager' }, null)))
      .toBe('Team introduction — Manager')
  })
})
