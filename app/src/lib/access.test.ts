import { describe, expect, it } from 'vitest'
import { accessSummary, friendlyAccessError, orderAccess } from './access'

const row = (label: string | null, status = 'granted') => ({
  system: label ? { label } : null,
  system_key: 'zzz_key',
  status,
})

describe('orderAccess', () => {
  it('reads in the same order every time, by the name on screen', () => {
    const rows = [row('VPN and network'), row('Email and calendar'), row('Building access')]
    expect(orderAccess(rows).map((r) => r.system?.label)).toEqual([
      'Building access',
      'Email and calendar',
      'VPN and network',
    ])
  })

  it('falls back to the key when a system has no label to show', () => {
    expect(orderAccess([row(null), row('Building access')])[0].system?.label).toBe('Building access')
  })
})

describe('accessSummary', () => {
  it('counts what is still open on the way out, because that is what somebody must act on', () => {
    expect(accessSummary([row('a'), row('b'), row('c', 'revoked')], 'offboarding')).toBe(
      '2 accounts still open, 1 already shut down.',
    )
    expect(accessSummary([row('a', 'revoked')], 'offboarding')).toBe('All 1 account shut down.')
  })

  it('says plainly when nothing was ever written down, rather than implying all clear', () => {
    expect(accessSummary([], 'offboarding')).toBe('Nothing was ever recorded for this person.')
  })

  it('counts what has been given on the way in', () => {
    expect(accessSummary([], 'onboarding')).toBe('What this person has been given. Nothing recorded yet.')
    expect(accessSummary([row('a')], 'onboarding')).toBe('1 account recorded.')
    expect(accessSummary([row('a'), row('b', 'revoked')], 'onboarding')).toBe('1 account recorded, 1 since removed.')
  })
})

describe('friendlyAccessError', () => {
  it('passes the database’s own sentence through', () => {
    const raised = 'Email and calendar is already recorded for this person.'
    expect(friendlyAccessError(raised)).toBe(raised)
  })

  it('translates the ones written for a machine', () => {
    expect(friendlyAccessError('violates row-level security policy')).toBe('You cannot change access for this person.')
    expect(friendlyAccessError('could not find the function in the schema cache')).toMatch(/newer than the database/)
  })
})
