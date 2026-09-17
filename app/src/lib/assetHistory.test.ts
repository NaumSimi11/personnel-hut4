import { describe, expect, it } from 'vitest'
import { assetHistory, type HistoryInput } from './assetHistory'

const input: HistoryInput = {
  createdAt: '2026-01-10T09:00:00Z',
  assignments: [
    { issued_at: '2026-02-01T10:00:00Z', returned_at: '2026-06-01T10:00:00Z', person: 'Ana Stojanova', return_condition: 'Scratched lid' },
    { issued_at: '2026-06-10T10:00:00Z', returned_at: null, person: 'Igor Lestar', return_condition: null },
  ],
  notes: [
    { happened_on: '2026-03-15', kind: 'service', body: 'Screen replaced under warranty', about: 'Ana Stojanova' },
  ],
  transfers: [
    { transferred_at: '2026-05-02T10:00:00Z', from: 'Liquiditas', to: 'Synami', by: 'Naum Simidjioski' },
  ],
}

describe('assetHistory', () => {
  it('puts everything that happened in one list, newest first', () => {
    const rows = assetHistory(input)
    expect(rows.map((r) => r.on)).toEqual([
      '2026-06-10', '2026-06-01', '2026-05-02', '2026-03-15', '2026-02-01', '2026-01-10',
    ])
  })

  it('reads an issue and a return as two separate events', () => {
    const rows = assetHistory(input)
    expect(rows.find((r) => r.on === '2026-02-01')?.text).toBe('Issued to Ana Stojanova')
    expect(rows.find((r) => r.on === '2026-06-01')?.text).toBe('Returned by Ana Stojanova · Scratched lid')
  })

  it('does not invent a return for something still held', () => {
    const rows = assetHistory(input)
    expect(rows.filter((r) => r.kind === 'returned')).toHaveLength(1)
  })

  it('keeps a service note with who had it at the time', () => {
    expect(assetHistory(input).find((r) => r.kind === 'service')?.text)
      .toBe('Screen replaced under warranty · while Ana Stojanova had it')
  })

  it('names both companies on a transfer', () => {
    expect(assetHistory(input).find((r) => r.kind === 'transferred')?.text)
      .toBe('Moved from Liquiditas to Synami by Naum Simidjioski')
  })

  it('always ends with the day it was registered', () => {
    const rows = assetHistory(input)
    expect(rows[rows.length - 1]).toMatchObject({ kind: 'registered', text: 'Registered' })
  })

  it('copes with an asset nothing has happened to', () => {
    const rows = assetHistory({ createdAt: '2026-01-10T09:00:00Z', assignments: [], notes: [], transfers: [] })
    expect(rows).toHaveLength(1)
    expect(rows[0].kind).toBe('registered')
  })

  it('ignores a reservation that was never issued', () => {
    // Reserved then cancelled is not part of the thing's history.
    const rows = assetHistory({
      createdAt: '2026-01-10T09:00:00Z',
      assignments: [{ issued_at: null, returned_at: null, person: 'Ana Stojanova', return_condition: null }],
      notes: [], transfers: [],
    })
    expect(rows).toHaveLength(1)
  })
})
