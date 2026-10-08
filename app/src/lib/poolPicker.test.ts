import { describe, expect, it } from 'vitest'
import { PICK_MIN_QUERY, pickPayload, pickSummary } from './poolPicker'
import { POOL_PAGE_SIZE } from './candidatePool'

describe('pickPayload', () => {
  it('lists the whole pool when nothing is typed, a page at a time', () => {
    expect(pickPayload('', 0)).toEqual({ q: null, limit: POOL_PAGE_SIZE, offset: 0 })
    expect(pickPayload('   ', 2)).toEqual({ q: null, limit: POOL_PAGE_SIZE, offset: 2 * POOL_PAGE_SIZE })
  })

  it('searches once the term is long enough, trimmed', () => {
    expect(pickPayload('  ana ', 0)).toEqual({ q: 'ana', limit: POOL_PAGE_SIZE, offset: 0 })
  })

  it('keeps listing while the term is still too short to search', () => {
    expect('a'.length).toBeLessThan(PICK_MIN_QUERY)
    expect(pickPayload('a', 0).q).toBeNull()
  })
})

describe('pickSummary', () => {
  it('counts the pool and what is shown', () => {
    expect(pickSummary(3611, 50, '')).toBe('3,611 people · showing 50 · most recently active first')
  })

  it('says matches while searching', () => {
    expect(pickSummary(12, 12, 'python')).toBe('12 people match “python”')
    expect(pickSummary(1, 1, 'ana')).toBe('1 person matches “ana”')
    expect(pickSummary(240, 50, 'dev')).toBe('240 people match “dev” · showing 50')
  })

  it('treats a too-short term as no search', () => {
    expect(pickSummary(3611, 50, 'a')).toBe('3,611 people · showing 50 · most recently active first')
  })
})
