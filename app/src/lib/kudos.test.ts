import { describe, expect, it } from 'vitest'
import { kudosInput, kudosValueInput, monthLabel, monthOptions } from './kudos'

describe('kudosInput', () => {
  const base = { from_person_id: 'p1', to_person_id: 'p2', message: '  Covered my shift  ', value_id: '', on_date: '2026-09-10' }
  it('trims the message, keeps the value optional and turns an empty value into null', () => {
    const parsed = kudosInput.safeParse(base)
    expect(parsed.success).toBe(true)
    if (parsed.success) {
      expect(parsed.data.message).toBe('Covered my shift')
      expect(parsed.data.value_id).toBeNull()
    }
  })
  it('refuses a kudos to oneself, an empty message, one over 280 characters, a missing date', () => {
    expect(kudosInput.safeParse({ ...base, to_person_id: 'p1' }).success).toBe(false)
    expect(kudosInput.safeParse({ ...base, message: '   ' }).success).toBe(false)
    expect(kudosInput.safeParse({ ...base, message: 'x'.repeat(281) }).success).toBe(false)
    expect(kudosInput.safeParse({ ...base, on_date: '' }).success).toBe(false)
    expect(kudosInput.safeParse({ ...base, to_person_id: '' }).success).toBe(false)
  })
})

describe('kudosValueInput', () => {
  it('needs a name up to 60 characters; the description is optional', () => {
    expect(kudosValueInput.safeParse({ name: ' Craft ', description: '', active: true }).success).toBe(true)
    expect(kudosValueInput.safeParse({ name: '', description: 'x', active: true }).success).toBe(false)
    expect(kudosValueInput.safeParse({ name: 'x'.repeat(61), description: '', active: true }).success).toBe(false)
  })
})

describe('months', () => {
  it('labels a month and offers "all" first with the total', () => {
    expect(monthLabel('2026-09')).toBe('September 2026')
    expect(monthLabel('2026-01')).toBe('January 2026')
    expect(monthOptions([{ month: '2026-09', count: 2 }, { month: '2026-08', count: 1 }], 3)).toEqual([
      { value: '', label: 'All months (3)' },
      { value: '2026-09', label: 'September 2026 (2)' },
      { value: '2026-08', label: 'August 2026 (1)' },
    ])
  })
})
