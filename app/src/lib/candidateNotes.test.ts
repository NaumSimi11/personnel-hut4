import { describe, expect, it } from 'vitest'
import { NOTES_PAGE_SIZE, NOTE_KINDS, canRemoveNote, noteActor, noteKindLabel } from './candidateNotes'

describe('NOTE_KINDS', () => {
  it('names the ten kinds of candidate_notes.kind, note first', () => {
    expect(NOTE_KINDS.map((k) => k.key)).toEqual([
      'note',
      'call',
      'message',
      'meeting',
      'status_change',
      'association',
      'unassociation',
      'review',
      'task',
      'other',
    ])
    expect(noteKindLabel('status_change')).toBe('Status change')
    expect(noteKindLabel('association')).toBe('Added to a job')
    expect(noteKindLabel('unassociation')).toBe('Removed from a job')
  })

  it('shows an unknown kind as itself rather than hiding the row', () => {
    expect(noteKindLabel('whatever')).toBe('whatever')
  })

  it('pages fifty at a time', () => {
    expect(NOTES_PAGE_SIZE).toBe(50)
  })
})

describe('noteActor', () => {
  it('prefers the linked person, then the kept Zoho name, then the system', () => {
    expect(noteActor({ actor: { full_name: 'Ada Lovelace' }, actor_name: 'ada' })).toBe('Ada Lovelace')
    expect(noteActor({ actor: null, actor_name: 'Zoho User' })).toBe('Zoho User')
    expect(noteActor({ actor: null, actor_name: null })).toBe('Zoho Recruit')
  })
})

describe('canRemoveNote', () => {
  it('is the author, or an admin', () => {
    expect(canRemoveNote({ actor_id: 'p1' }, { personId: 'p1', isAdmin: false })).toBe(true)
    expect(canRemoveNote({ actor_id: 'p1' }, { personId: 'p2', isAdmin: false })).toBe(false)
    expect(canRemoveNote({ actor_id: 'p1' }, { personId: 'p2', isAdmin: true })).toBe(true)
  })

  it('never matches an imported note without an actor to a signed-out viewer', () => {
    expect(canRemoveNote({ actor_id: null }, { personId: null, isAdmin: false })).toBe(false)
    expect(canRemoveNote({ actor_id: null }, { personId: 'p1', isAdmin: false })).toBe(false)
  })
})
