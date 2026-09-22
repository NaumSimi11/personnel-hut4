import { describe, expect, it } from 'vitest'
import { BLANK, POOL_OWNER_LABEL, inventoryHeading, inventoryRows, localToday } from './inventoryPrint'

const names = { types: { laptop: 'Laptop' }, companies: { c1: 'Hut4' } }
const base = {
  asset_tag: 'HUT-001',
  type_key: 'laptop',
  model: 'MacBook Air',
  serial_number: 'SER1',
  inventory_number: 'INV1',
  company_id: 'c1' as string | null,
  status: 'assigned',
  holder_note: null as string | null,
  holderName: 'Ana' as string | null,
}

describe('inventoryRows', () => {
  it('names the type, the company and the status the way the app does', () => {
    const [row] = inventoryRows([base], names)
    expect(row).toEqual({
      tag: 'HUT-001', type: 'Laptop', model: 'MacBook Air', serial: 'SER1',
      inventory: 'INV1', owner: 'Hut4', status: 'Assigned', holder: 'Ana',
    })
  })

  it('calls an asset with no company the holding pool', () => {
    expect(inventoryRows([{ ...base, company_id: null }], names)[0].owner).toBe(POOL_OWNER_LABEL)
  })

  it('falls back to the books when nothing is assigned, and says so', () => {
    const [row] = inventoryRows([{ ...base, holderName: null, holder_note: 'Sales office' }], names)
    expect(row.holder).toBe('Sales office (per the books)')
  })

  it('prefers a live assignment over the books', () => {
    expect(inventoryRows([{ ...base, holder_note: 'Sales office' }], names)[0].holder).toBe('Ana')
  })

  it('writes one blank for every empty cell, including whitespace', () => {
    const [row] = inventoryRows(
      [{ ...base, model: null, serial_number: '  ', inventory_number: '', holderName: null }],
      names,
    )
    expect([row.model, row.serial, row.inventory, row.holder]).toEqual([BLANK, BLANK, BLANK, BLANK])
  })

  it('falls back to the raw key for a type it does not know', () => {
    expect(inventoryRows([{ ...base, type_key: 'mystery' }], names)[0].type).toBe('mystery')
  })
})

describe('inventoryHeading', () => {
  it('counts the items and dates the page', () => {
    expect(inventoryHeading(1, '23 Sep 2026')).toBe('1 item · printed 23 Sep 2026')
    expect(inventoryHeading(12, '23 Sep 2026')).toBe('12 items · printed 23 Sep 2026')
  })
})

describe('localToday', () => {
  it('gives the calendar day the person is on, in any time zone', () => {
    // Built from local parts, so this is 23 Sep locally wherever the test runs —
    // the UTC slice would say the 22nd or the 24th depending on the offset.
    expect(localToday(new Date(2026, 8, 23, 23, 30))).toBe('2026-09-23')
    expect(localToday(new Date(2026, 0, 1, 0, 5))).toBe('2026-01-01')
  })

  it('pads month and day, so longDate can parse it', () => {
    expect(localToday(new Date(2026, 2, 7, 12, 0))).toBe('2026-03-07')
  })
})
