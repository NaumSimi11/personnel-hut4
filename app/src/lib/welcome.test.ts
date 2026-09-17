import { describe, expect, it } from 'vitest'
import { addressChoices, sentLine } from './welcome'

describe('welcome note', () => {
  it('offers the addresses on the record, the personal one first', () => {
    expect(addressChoices({ personal_email: 'a@home.test', work_email: 'a@co.test' })).toEqual([
      { key: 'personal', label: 'Personal email · a@home.test' },
      { key: 'work', label: 'Work email · a@co.test' },
    ])
    expect(addressChoices({ personal_email: null, work_email: 'a@co.test' })).toEqual([{ key: 'work', label: 'Work email · a@co.test' }])
    expect(addressChoices({ personal_email: null, work_email: null })).toEqual([])
  })
  it('says when and where it last went', () => {
    expect(sentLine(null, null)).toBe('Not sent yet.')
    expect(sentLine('2026-09-17T10:00:00Z', 'personal')).toBe('Last sent 17 Sep 2026 to the personal email.')
    expect(sentLine('2026-09-17T10:00:00Z', 'work')).toBe('Last sent 17 Sep 2026 to the work email.')
  })
})
