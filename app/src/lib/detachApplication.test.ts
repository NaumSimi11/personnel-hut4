import { describe, expect, it } from 'vitest'
import { countOf, detachable, friendlyDetachError, type DetachTarget } from './detachApplication'

const row = (over: Partial<DetachTarget> = {}): DetachTarget => ({
  stage_key: 'new',
  owner_id: null,
  next_action: null,
  employment_period_id: null,
  source_provider: null,
  events: 0,
  interviews: 0,
  offers: 0,
  files: 0,
  ...over,
})

describe('detachable', () => {
  it('allows an attachment that is still nothing but an attachment', () => {
    expect(detachable(row(), true)).toEqual({ canDetach: true, reason: null })
  })

  it('refuses without the capability, whatever the row looks like', () => {
    expect(detachable(row(), false).canDetach).toBe(false)
    expect(detachable(row(), false).reason).toMatch(/cannot change applications/)
  })

  it('refuses an imported row, and names where it came from', () => {
    const v = detachable(row({ source_provider: 'zoho_recruit' }), true)
    expect(v.canDetach).toBe(false)
    expect(v.reason).toContain('zoho_recruit')
  })

  it('refuses once somebody was hired from it', () => {
    expect(detachable(row({ employment_period_id: 'e1' }), true).reason).toMatch(/hired/)
  })

  it('refuses while somebody is carrying it: they were emailed when it was given to them', () => {
    expect(detachable(row({ owner_id: 'p1' }), true).reason).toMatch(/assigned to somebody/)
    // A next action with no owner is still a promise somebody made.
    expect(detachable(row({ next_action: 'Call back Tuesday' }), true).canDetach).toBe(false)
  })

  it('refuses once it has moved past New', () => {
    expect(detachable(row({ stage_key: 'screening' }), true).reason).toMatch(/moved on from New/)
    expect(detachable(row({ stage_key: 'rejected' }), true).canDetach).toBe(false)
  })

  it('refuses when anything at all has been recorded against it', () => {
    expect(detachable(row({ interviews: 1 }), true).reason).toMatch(/interview/)
    expect(detachable(row({ offers: 1 }), true).reason).toMatch(/offer/)
    expect(detachable(row({ files: 1 }), true).reason).toMatch(/file/)
    expect(detachable(row({ events: 1 }), true).reason).toMatch(/recorded/)
  })

  it('checks the permanent reasons before the ones that might change', () => {
    // A hired row that also has interviews reads as hired: the sentence that
    // will still be true tomorrow is the more useful one.
    expect(detachable(row({ employment_period_id: 'e1', interviews: 2 }), true).reason).toMatch(/hired/)
  })
})

describe('countOf', () => {
  it('reads an embedded count, however PostgREST answers', () => {
    expect(countOf([{ count: 3 }])).toBe(3)
    expect(countOf([])).toBe(0)
    expect(countOf(null)).toBe(0)
    expect(countOf(undefined)).toBe(0)
  })
})

describe('friendlyDetachError', () => {
  it('passes the database’s own sentence through', () => {
    const raised = 'Ana Ilievska has an offer on this job. Reject or withdraw it instead.'
    expect(friendlyDetachError(raised)).toBe(raised)
  })

  it('translates the one written for a machine', () => {
    expect(friendlyDetachError('new row violates row-level security policy')).toBe(
      'You cannot change applications in this company.',
    )
  })
})
