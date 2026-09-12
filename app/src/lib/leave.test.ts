import { describe, expect, it } from 'vitest'
import {
  cancellationState,
  leaveActions,
  leaveInput,
  leaveStatusLabel,
  monthGrid,
  workingDaysBetween,
} from './leave'

describe('workingDaysBetween', () => {
  it('excludes weekends, the holidays and closures given', () => {
    expect(workingDaysBetween('2027-03-01', '2027-03-07', ['2027-03-03'], ['2027-03-04'])).toBe(3)
    expect(workingDaysBetween('2027-03-06', '2027-03-07', [], [])).toBe(0)
    expect(workingDaysBetween('2027-03-07', '2027-03-01', [], [])).toBe(0)
  })
})

describe('leaveInput', () => {
  it('needs a type and an ordered date range', () => {
    expect(leaveInput.safeParse({ leaveTypeKey: 'annual', start: '2027-03-01', end: '2027-03-05', note: '', documentsToFollow: false }).success).toBe(true)
    expect(leaveInput.safeParse({ leaveTypeKey: 'annual', start: '2027-03-05', end: '2027-03-01', note: '', documentsToFollow: false }).success).toBe(false)
    expect(leaveInput.safeParse({ leaveTypeKey: '', start: '2027-03-01', end: '2027-03-05', note: '', documentsToFollow: false }).success).toBe(false)
  })
})

describe('leaveActions', () => {
  const today = '2027-03-10'
  it('lets the owner cancel before the start, ask after; approvers decide and cancel', () => {
    const mine = { person_id: 'me', status: 'approved', start_date: '2027-03-20', cancellation_requested_at: null, cancellation_declined_at: null }
    expect(leaveActions(mine, { personId: 'me', canApprove: false }, today).map((a) => a.key)).toEqual(['cancel'])
    const started = { ...mine, start_date: '2027-03-01' }
    expect(leaveActions(started, { personId: 'me', canApprove: false }, today).map((a) => a.key)).toEqual(['ask'])
    const pending = { ...mine, status: 'pending', person_id: 'other' }
    expect(leaveActions(pending, { personId: 'me', canApprove: true }, today).map((a) => a.key)).toEqual(['approve', 'reject', 'cancel'])
    expect(leaveActions({ ...pending, person_id: 'me' }, { personId: 'me', canApprove: true }, today).map((a) => a.key)).toEqual(['cancel'])
    expect(leaveActions({ ...mine, status: 'cancelled' }, { personId: 'me', canApprove: true }, today)).toEqual([])
  })
  it('names the cancellation state from the timestamps', () => {
    expect(cancellationState({ status: 'approved', cancellation_requested_at: null, cancellation_declined_at: null })).toBe('none')
    expect(cancellationState({ status: 'approved', cancellation_requested_at: '2027-03-01T10:00:00Z', cancellation_declined_at: null })).toBe('open')
    expect(cancellationState({ status: 'approved', cancellation_requested_at: '2027-03-01T10:00:00Z', cancellation_declined_at: '2027-03-02T10:00:00Z' })).toBe('declined')
    expect(cancellationState({ status: 'approved', cancellation_requested_at: '2027-03-03T10:00:00Z', cancellation_declined_at: '2027-03-02T10:00:00Z' })).toBe('open')
    expect(leaveStatusLabel('pending')).toBe('Pending')
  })
})

describe('monthGrid', () => {
  it('lays a month out Monday-first with leading and trailing days', () => {
    const grid = monthGrid(2027, 3) // March 2027 starts on a Monday
    expect(grid.length % 7).toBe(0)
    expect(grid[0]?.iso).toBe('2027-03-01')
    expect(grid[30]?.iso).toBe('2027-03-31')
    expect(grid.filter((d) => d.inMonth).length).toBe(31)
    const feb = monthGrid(2027, 2) // starts on a Monday too; 28 days → exactly 4 rows
    expect(feb.length).toBe(28)
  })
})
