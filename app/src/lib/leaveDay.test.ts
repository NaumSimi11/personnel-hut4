import { describe, expect, it } from 'vitest'
import { dayStanding, dayHeadline, leaveStanding } from './leaveDay'

const TODAY = '2026-09-17'

describe('dayStanding', () => {
  it('knows a day that has been from one that is to come', () => {
    expect(dayStanding('2026-09-10', TODAY)).toBe('past')
    expect(dayStanding('2026-09-17', TODAY)).toBe('today')
    expect(dayStanding('2026-09-24', TODAY)).toBe('future')
  })
})

describe('dayHeadline', () => {
  it('speaks of a past working day in the past tense', () => {
    // "Working day · A normal day" for the 10th of last week reads as though
    // the app is describing the calendar rather than what happened.
    expect(dayHeadline('working', 'past')).toEqual({ title: 'Was a working day', sub: 'A normal day' })
  })

  it('leaves today alone', () => {
    expect(dayHeadline('working', 'today')).toEqual({ title: 'Working day', sub: 'A normal day' })
  })

  it('looks forward to a day still coming', () => {
    expect(dayHeadline('working', 'future')).toEqual({ title: 'A working day', sub: 'A normal day' })
  })

  it('does the same for the other kinds of day', () => {
    expect(dayHeadline('holiday', 'past').title).toBe('Was a public holiday')
    expect(dayHeadline('weekend', 'past').title).toBe('Was a weekend')
    expect(dayHeadline('closure', 'past').title).toBe('Was a company closure')
    expect(dayHeadline('holiday', 'future').title).toBe('Public holiday')
  })
})

describe('leaveStanding', () => {
  it('reports a leave that has finished as finished, whatever day you clicked', () => {
    // Clicking the 10th shows "working day 8 of 9" — true of that day, and
    // misleading today, when the whole leave is over and spent.
    expect(leaveStanding({ start: '2026-08-31', end: '2026-09-11' }, TODAY)).toBe('finished')
  })

  it('reports one still running', () => {
    expect(leaveStanding({ start: '2026-09-14', end: '2026-09-25' }, TODAY)).toBe('running')
  })

  it('reports one not yet begun', () => {
    expect(leaveStanding({ start: '2026-10-01', end: '2026-10-10' }, TODAY)).toBe('upcoming')
  })

  it('counts the first and last day as part of it', () => {
    expect(leaveStanding({ start: TODAY, end: '2026-09-20' }, TODAY)).toBe('running')
    expect(leaveStanding({ start: '2026-09-01', end: TODAY }, TODAY)).toBe('running')
  })

  it('treats an open-ended leave as running once it has begun', () => {
    expect(leaveStanding({ start: '2026-09-01', end: null }, TODAY)).toBe('running')
  })
})
