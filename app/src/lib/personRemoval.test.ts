import { describe, expect, it } from 'vitest'
import { personRemovable, removalConfirmation } from './personRemoval'

const someone = { employed: false, isSelf: false }

describe('personRemovable', () => {
  it('lets an admin remove someone who has left and is not themselves', () => {
    expect(personRemovable(someone, true)).toEqual({ canRemove: true, reason: null })
  })

  it('refuses anyone who is not a platform admin', () => {
    expect(personRemovable(someone, false)).toEqual({
      canRemove: false,
      reason: 'Only platform admins remove people from the directory.',
    })
  })

  it('refuses removing yourself, even as an admin', () => {
    const verdict = personRemovable({ ...someone, isSelf: true }, true)
    expect(verdict.canRemove).toBe(false)
    expect(verdict.reason).toContain('yourself')
  })

  it('sends a current employee through offboarding first', () => {
    const verdict = personRemovable({ ...someone, employed: true }, true)
    expect(verdict.canRemove).toBe(false)
    expect(verdict.reason).toContain('Offboard them first')
  })

  it('checks permission before anything else, so a non-admin is never told why someone else is unremovable', () => {
    expect(personRemovable({ employed: true, isSelf: true }, false).reason).toContain('platform admins')
  })
})

describe('removalConfirmation', () => {
  it('promises the history stays and the removal can be undone', () => {
    const text = removalConfirmation('Ana')
    expect(text).toContain('Ana')
    expect(text).toContain('history stays')
    expect(text).toContain('restore')
  })
})
