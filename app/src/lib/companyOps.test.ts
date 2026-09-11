import { describe, expect, it } from 'vitest'
import { awaitingLabel, upcoming } from './companyOps'

const today = '2026-09-11'

describe('upcoming', () => {
  const periods = [
    { id: 'a', status: 'active', start_date: '2024-01-01', end_date: null, last_working_date: null },
    { id: 'b', status: 'pre_start', start_date: '2026-11-01', end_date: null, last_working_date: null },
    { id: 'c', status: 'pre_start', start_date: '2026-10-01', end_date: null, last_working_date: null },
    { id: 'd', status: 'active', start_date: '2023-05-01', end_date: '2026-12-31', last_working_date: '2026-12-15' },
    { id: 'e', status: 'active', start_date: '2023-05-01', end_date: '2026-09-30', last_working_date: null },
    { id: 'f', status: 'former', start_date: '2020-01-01', end_date: '2021-01-01', last_working_date: null },
    { id: 'g', status: 'active', start_date: '2023-05-01', end_date: '2026-09-01', last_working_date: null },
  ]

  it('lists starters soonest first and departures by end date, ignoring the past and former', () => {
    const out = upcoming(periods, today)
    expect(out.starters.map((p) => p.id)).toEqual(['c', 'b'])
    expect(out.departures.map((p) => p.id)).toEqual(['e', 'd'])
  })

  it('keeps an overdue pre-start person visible — nothing flips them to active automatically', () => {
    const overdue = { id: "h", status: "pre_start", start_date: "2026-09-01", end_date: null, last_working_date: null }
    expect(upcoming([overdue, periods[2]!], today).starters.map((p) => p.id)).toEqual(["h", "c"])
  })

  it('is empty when nothing is scheduled', () => {
    expect(upcoming([periods[0]!], today)).toEqual({ starters: [], departures: [] })
  })
})

describe('awaitingLabel', () => {
  it('names the configured approver or says none is configured', () => {
    expect(awaitingLabel({ person: { full_name: 'Ana Ilic' } })).toBe('Awaiting Ana Ilic')
    expect(awaitingLabel({ person: null })).toBe('Awaiting approval · no approver configured')
    expect(awaitingLabel(undefined)).toBe('Awaiting approval · no approver configured')
  })
})
