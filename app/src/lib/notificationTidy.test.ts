import { describe, expect, it } from 'vitest'
import { deleteConfirm, tidyNotice, toggleAll, toggleOne } from './notificationTidy'

describe('toggleAll', () => {
  it('selects every shown row when some or none are picked', () => {
    expect(toggleAll([], ['a', 'b'])).toEqual(['a', 'b'])
    expect(toggleAll(['a'], ['a', 'b'])).toEqual(['a', 'b'])
  })

  it('clears them when all are already picked', () => {
    expect(toggleAll(['b', 'a'], ['a', 'b'])).toEqual([])
  })

  it('selects nothing from an empty list', () => {
    expect(toggleAll([], [])).toEqual([])
  })
})

describe('toggleOne', () => {
  it('adds once and removes', () => {
    expect(toggleOne(['a'], 'b', true)).toEqual(['a', 'b'])
    expect(toggleOne(['a'], 'a', true)).toEqual(['a'])
    expect(toggleOne(['a', 'b'], 'a', false)).toEqual(['b'])
  })
})

describe('deleteConfirm', () => {
  it('names how many, and that it cannot be undone', () => {
    expect(deleteConfirm(6, 'picked')).toEqual({
      title: 'Delete 6 notifications?',
      hint: 'They are gone for good — this cannot be undone. Archive them instead to keep them out of sight.',
    })
  })

  it('says which heap for the all-at-once forms', () => {
    expect(deleteConfirm(1, 'read').title).toBe('Delete your 1 read notification?')
    expect(deleteConfirm(12_345, 'read').title).toBe('Delete all 12,345 read notifications?')
    expect(deleteConfirm(3, 'archived').title).toBe('Delete all 3 archived notifications?')
    expect(deleteConfirm(3, 'archived').hint).toBe('They are gone for good — this cannot be undone.')
  })
})

describe('tidyNotice', () => {
  it('says what was done, in the singular when one', () => {
    expect(tidyNotice('archived', 6)).toBe('Archived 6 notifications. They are under Archived.')
    expect(tidyNotice('restored', 1)).toBe('Restored 1 notification.')
    expect(tidyNotice('deleted', 1_000)).toBe('Deleted 1,000 notifications.')
  })

  it('says so when there was nothing to do', () => {
    expect(tidyNotice('deleted', 0)).toBe('Nothing to delete.')
    expect(tidyNotice('archived', 0)).toBe('Nothing to archive.')
  })
})
