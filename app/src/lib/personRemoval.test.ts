import { describe, expect, it } from 'vitest'
import { deletionNeedsForce, deletionSummary, personDeletable, personRemovable, removalConfirmation, type DeletionCost } from './personRemoval'

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

describe('personDeletable', () => {
  it('lets an admin delete anyone but themselves, employed or not', () => {
    expect(personDeletable({ isSelf: false }, true)).toEqual({ canDelete: true, reason: null })
  })

  it('refuses anyone who is not a platform admin', () => {
    expect(personDeletable({ isSelf: false }, false).reason).toContain('platform admins')
  })

  it('refuses deleting yourself', () => {
    const verdict = personDeletable({ isSelf: true }, true)
    expect(verdict.canDelete).toBe(false)
    expect(verdict.reason).toContain('yourself')
  })
})

describe('deletionSummary', () => {
  const nothing: DeletionCost = {
    employments: 0, leave_requests: 0, documents: 0, kudos: 0, tasks: 0, equipment: 0, checklists: 0, has_sign_in: false,
  }

  it('names each kind of record that goes, in the order the reader expects', () => {
    const text = deletionSummary({ ...nothing, employments: 2, leave_requests: 14, documents: 3, kudos: 1, has_sign_in: true })
    expect(text).toBe('2 employments, 14 leave requests, 3 documents, 1 kudos, and their sign-in')
  })

  it('says one thing plainly when only one thing goes', () => {
    expect(deletionSummary({ ...nothing, tasks: 1 })).toBe('1 task')
    expect(deletionSummary({ ...nothing, has_sign_in: true })).toBe('their sign-in')
  })

  it('says so when nothing else is on record', () => {
    expect(deletionSummary(nothing)).toBe('nothing else on record')
  })

  it('pluralises the awkward ones', () => {
    expect(deletionSummary({ ...nothing, equipment: 2, checklists: 2, kudos: 3 })).toBe('3 kudos, 2 equipment records, and 2 checklists')
  })
})

describe('deletionNeedsForce', () => {
  it('is false for a record that was never anybody', () => {
    expect(deletionNeedsForce({ employments: 0, leave_requests: 0, documents: 0, kudos: 0, tasks: 0, equipment: 0, checklists: 0, has_sign_in: false })).toBe(false)
  })
  it('is true as soon as anything is on record', () => {
    expect(deletionNeedsForce({ employments: 0, leave_requests: 0, documents: 0, kudos: 0, tasks: 1, equipment: 0, checklists: 0, has_sign_in: false })).toBe(true)
  })
})
