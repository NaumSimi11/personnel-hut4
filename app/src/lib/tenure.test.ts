import { describe, expect, it } from 'vitest'
import { tenureLabel } from './tenure'

describe('tenureLabel', () => {
  const today = '2026-09-14'
  it('speaks in years and months for ongoing employment', () => {
    expect(tenureLabel('2026-01-01', null, today)).toBe('8 months')
    expect(tenureLabel('2024-02-01', null, today)).toBe('2 years 7 months')
    expect(tenureLabel('2025-09-01', null, today)).toBe('1 year')
    expect(tenureLabel('2026-09-01', null, today)).toBe('2 weeks')
    expect(tenureLabel('2026-09-12', null, today)).toBe('2 days')
    expect(tenureLabel('2026-09-14', null, today)).toBe('today')
  })
  it('counts to the end date once there is one, and looks ahead for a future start', () => {
    expect(tenureLabel('2024-02-01', '2026-03-01', today)).toBe('2 years 1 month')
    expect(tenureLabel('2026-10-01', null, today)).toBe('starts in 17 days')
  })
})
