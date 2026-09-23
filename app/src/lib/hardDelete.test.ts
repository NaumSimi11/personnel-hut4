import { describe, expect, it } from 'vitest'
import { bodyEditable, candidateDeletable, friendlyHardDeleteError, policyDeletable } from './hardDelete'

describe('policyDeletable', () => {
  it('allows one nobody has agreed to, published or not', () => {
    expect(policyDeletable({ acknowledgements: 0, status: 'draft' }, true).canDelete).toBe(true)
    expect(policyDeletable({ acknowledgements: 0, status: 'published' }, true).canDelete).toBe(true)
  })

  it('refuses once somebody has agreed, and counts them', () => {
    expect(policyDeletable({ acknowledgements: 1, status: 'published' }, true).reason).toMatch(/1 person already agreed/)
    expect(policyDeletable({ acknowledgements: 4, status: 'published' }, true).reason).toMatch(/4 people already agreed/)
  })

  it('refuses without the capability', () => {
    expect(policyDeletable({ acknowledgements: 0, status: 'draft' }, false).canDelete).toBe(false)
  })
})

describe('bodyEditable', () => {
  it('lets a draft be rewritten and a published one only re-published', () => {
    expect(bodyEditable({ status: 'draft' })).toBe(true)
    expect(bodyEditable({ status: 'published' })).toBe(false)
  })
})

describe('candidateDeletable', () => {
  const bare = { applications: 0, notes: 0, files: 0, do_not_contact: false }

  it('allows a record that is nothing but a name', () => {
    expect(candidateDeletable(bare, true)).toEqual({ canDelete: true, reason: null })
  })

  it('never forgets somebody who asked not to be contacted', () => {
    expect(candidateDeletable({ ...bare, do_not_contact: true }, true).reason).toMatch(/sourced afresh/)
  })

  it('refuses when anything is attached, naming it', () => {
    expect(candidateDeletable({ ...bare, applications: 2 }, true).reason).toMatch(/2 applications on record/)
    expect(candidateDeletable({ ...bare, notes: 1 }, true).reason).toMatch(/1 note about them/)
    expect(candidateDeletable({ ...bare, files: 3 }, true).reason).toMatch(/3 documents on file/)
  })

  it('puts the contact rule before the counts, because it outlives them', () => {
    expect(candidateDeletable({ applications: 5, notes: 5, files: 5, do_not_contact: true }, true).reason).toMatch(
      /never to be contacted/,
    )
  })

  it('refuses without the pool capability', () => {
    expect(candidateDeletable(bare, false).reason).toMatch(/Work the talent pool/)
  })
})

describe('friendlyHardDeleteError', () => {
  it("passes the database's own sentence through", () => {
    const raised = '3 people have already agreed to "Code of Conduct". Archive it instead.'
    expect(friendlyHardDeleteError(raised)).toBe(raised)
  })
})
