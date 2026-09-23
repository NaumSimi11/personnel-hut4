import { describe, expect, it } from 'vitest'
import { actionLabel, activityCount, entityLabel, periodStart, summarizeChange } from './activity'

describe('summarizeChange', () => {
  it('lists the fields that differ on an update, old → new, skipping bookkeeping columns', () => {
    const before = { id: '1', job_title: 'Clerk', status: 'active', updated_at: 'a', manager_id: null, custom: { x: 1 } }
    const after = { id: '1', job_title: 'Senior Clerk', status: 'active', updated_at: 'b', manager_id: 'm1', custom: { x: 2 } }
    expect(summarizeChange('UPDATE', before, after)).toEqual(['Job title: Clerk → Senior Clerk', 'Manager: — → m1', 'Custom: changed'])
  })

  it('names the notable fields set on an insert and the identity on a delete, truncating long values', () => {
    const row = { id: '1', title: 'Warehouse Lead role with a very long title that goes on and on beyond forty chars', status: 'draft', created_at: 'x' }
    expect(summarizeChange('INSERT', null, row)).toEqual(['Title: Warehouse Lead role with a very long ti…', 'Status: draft'])
    expect(summarizeChange('DELETE', row, null)).toEqual(['Title: Warehouse Lead role with a very long ti…'])
  })

  it('caps the list', () => {
    const before = { a: 1, b: 1, c: 1, d: 1, e: 1, f: 1 }
    const after = { a: 2, b: 2, c: 2, d: 2, e: 2, f: 2 }
    expect(summarizeChange('UPDATE', before, after)).toHaveLength(5)
    expect(summarizeChange('UPDATE', before, after)[4]).toBe('… and 2 more')
  })
})

describe('labels', () => {
  it('names entities and actions for people', () => {
    expect(entityLabel('employment_periods')).toBe('Employment')
    expect(entityLabel('unknown_table')).toBe('unknown table')
    expect(actionLabel('INSERT')).toBe('created')
    expect(actionLabel('DELETE')).toBe('removed')
  })
})

describe('reading the trail (plan 059)', () => {
  const NOW = new Date('2026-09-23T14:30:00Z')

  it('starts a period at UTC midnight, so it does not drift with the hour', () => {
    expect(periodStart('30', NOW)).toBe('2026-08-24T00:00:00.000Z')
    expect(periodStart('7', NOW)).toBe('2026-09-16T00:00:00.000Z')
    expect(periodStart('90', NOW)).toBe('2026-06-25T00:00:00.000Z')
  })

  it('has no start for all time', () => {
    expect(periodStart('all', NOW)).toBeNull()
  })

  it('says what is on screen without pretending it is everything', () => {
    expect(activityCount(1, 200)).toBe('1 change')
    expect(activityCount(37, 200)).toBe('37 changes')
    expect(activityCount(200, 200)).toBe('the 200 most recent changes')
  })
})
