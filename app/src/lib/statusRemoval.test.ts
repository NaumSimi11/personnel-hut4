import { describe, expect, it } from 'vitest'
import { removalNotice, removalPlan } from './statusRemoval'

describe('removalPlan', () => {
  it('deletes a status nobody ever used', () => {
    expect(removalPlan({ applications: 0, history: 0 }, 'Typo status')).toEqual({
      mode: 'delete',
      summary: 'Nobody has used “Typo status”. It will be deleted.',
      confirmLabel: 'Delete status',
    })
  })

  it('retires one that only old timelines mention, so they still read', () => {
    expect(removalPlan({ applications: 0, history: 3 }, 'No-show')).toEqual({
      mode: 'retire',
      summary: 'No application has “No-show” now, but 3 timeline entries mention it, so it will be retired and they will still read.',
      confirmLabel: 'Remove status',
    })
  })

  it('asks where the applications go when some still have it', () => {
    expect(removalPlan({ applications: 1, history: 0 }, 'Interview 4')).toEqual({
      mode: 'move',
      summary: '“Interview 4” is on 1 application.',
      confirmLabel: 'Remove status',
    })
    expect(removalPlan({ applications: 1332, history: 9 }, 'Job closed').summary).toBe('“Job closed” is on 1,332 applications.')
  })

  it('says one timeline entry, not one entries', () => {
    expect(removalPlan({ applications: 0, history: 1 }, 'X').summary).toContain('1 timeline entry mentions it')
  })
})

describe('removalNotice', () => {
  it('names the move and the outcome', () => {
    expect(removalNotice({ moved: 2, outcome: 'retired' }, 'Unqualified', 'Rejected by HR')).toBe(
      'Moved 2 applications from “Unqualified” to “Rejected by HR”, and retired “Unqualified”.',
    )
  })

  it('says so when the applications were left where they are', () => {
    expect(removalNotice({ moved: 0, outcome: 'retired' }, 'Task', null)).toBe(
      'Retired “Task”. Applications that have it keep it; nobody can pick it any more.',
    )
  })

  it('says deleted for a status nobody used', () => {
    expect(removalNotice({ moved: 0, outcome: 'deleted' }, 'Typo status', null)).toBe('Deleted “Typo status”.')
  })

  it('counts one application in the singular', () => {
    expect(removalNotice({ moved: 1, outcome: 'retired' }, 'A', 'B')).toBe('Moved 1 application from “A” to “B”, and retired “A”.')
  })
})
