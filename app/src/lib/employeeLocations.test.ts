import { describe, expect, it } from 'vitest'
import { locationName, locationSummary, missingFirst } from './employeeLocations'

describe("the company's people and their locations (25 Nov)", () => {
  const rows = [
    { period_id: '1', full_name: 'Zora', location_id: 'l1' },
    { period_id: '2', full_name: 'Ana', location_id: null },
    { period_id: '3', full_name: 'Bojan', location_id: 'l2' },
    { period_id: '4', full_name: 'Marko', location_id: null },
  ]

  it('counts who still has no location', () => {
    expect(locationSummary(rows)).toEqual({ total: 4, missing: 2, line: '2 of 4 people have no location yet.' })
    expect(locationSummary(rows.filter((r) => r.location_id)).line).toBe('Everyone working here has a location.')
    expect(locationSummary([]).line).toBe('Nobody is working here right now.')
  })

  it('lists the people without a location first, then by name', () => {
    expect(missingFirst(rows).map((r) => r.full_name)).toEqual(['Ana', 'Marko', 'Bojan', 'Zora'])
    expect(rows.at(0)?.full_name).toBe('Zora')
  })
})

describe('a typed location (25 Nov: Struga, Skopje, Lithuania…)', () => {
  it('takes any place name of 2 to 80 characters, trimmed, with single spaces', () => {
    expect(locationName.safeParse('  Struga ').data).toBe('Struga')
    expect(locationName.safeParse('Vilnius,   Lithuania').data).toBe('Vilnius, Lithuania')
    expect(locationName.safeParse('S').success).toBe(false)
    expect(locationName.safeParse('x'.repeat(81)).success).toBe(false)
    expect(locationName.safeParse('').error?.issues[0]?.message).toBe('Type where they work, e.g. Skopje, Struga or Vilnius, Lithuania.')
  })
})
