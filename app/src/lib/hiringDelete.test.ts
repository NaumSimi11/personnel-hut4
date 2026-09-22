import { describe, expect, it } from 'vitest'
import { friendlyDeleteError, jobDeletable, requestDeletable } from './hiringDelete'

describe('jobDeletable', () => {
  it('allows a job nobody has applied to', () => {
    expect(jobDeletable({ applications: 0 }, true)).toEqual({ canDelete: true, reason: null })
  })

  it('refuses a job with applications, and counts them in the reason', () => {
    expect(jobDeletable({ applications: 1 }, true).reason).toContain('1 application came in')
    expect(jobDeletable({ applications: 4 }, true).reason).toContain('4 applications came in')
    expect(jobDeletable({ applications: 1 }, true).canDelete).toBe(false)
  })

  it('refuses without the capability, whatever the count', () => {
    expect(jobDeletable({ applications: 0 }, false)).toEqual({
      canDelete: false,
      reason: 'You do not have permission to delete this.',
    })
  })
})

describe('requestDeletable', () => {
  it('allows a request that never became a job', () => {
    expect(requestDeletable({ hasJob: false }, true).canDelete).toBe(true)
  })

  it('refuses a request a job was opened from, and says which way round to do it', () => {
    const verdict = requestDeletable({ hasJob: true }, true)
    expect(verdict.canDelete).toBe(false)
    expect(verdict.reason).toContain('Delete the job first')
  })

  it('refuses without the capability', () => {
    expect(requestDeletable({ hasJob: false }, false).canDelete).toBe(false)
  })
})

describe('friendlyDeleteError', () => {
  it('turns the foreign-key refusal into something a person can act on', () => {
    expect(friendlyDeleteError('update or delete on table "jobs" violates foreign key constraint')).toContain(
      'Something is already attached',
    )
  })

  it('names the permission problem for an RLS refusal', () => {
    expect(friendlyDeleteError('new row violates row-level security policy')).toBe(
      'You do not have permission to delete this.',
    )
  })

  it('passes anything else through unchanged', () => {
    expect(friendlyDeleteError('connection reset')).toBe('connection reset')
  })
})
