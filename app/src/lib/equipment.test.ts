import { describe, expect, it } from 'vitest'
import { assetInput, assetStatusLabel, assignmentActions, itRequestActions, itRequestInput, kitItems, kitProgress, ownerLabel, parseSystems, returnActions, returnStatusLine, tidyKit, type EquipmentReturn } from './equipment'

describe('assetInput', () => {
  it('needs a tag and a type; the rest is optional', () => {
    expect(assetInput.safeParse({ assetTag: 'lt-1', typeKey: 'laptop', model: '', serialNumber: '', locationId: '', note: '' }).success).toBe(true)
    expect(assetInput.safeParse({ assetTag: 'x', typeKey: 'laptop', model: '', serialNumber: '', locationId: '', note: '' }).success).toBe(false)
    expect(assetInput.safeParse({ assetTag: 'lt-1', typeKey: '', model: '', serialNumber: '', locationId: '', note: '' }).success).toBe(false)
  })
})

describe('assignmentActions', () => {
  const can = (caps: string[]) => (cap: string) => caps.includes(cap)
  it('mirrors the functions: reserve when available, issue or cancel a reservation, return when issued', () => {
    expect(assignmentActions({ status: 'available' }, null, can(['it.assign']))).toEqual([{ key: 'reserve', label: 'Reserve' }])
    expect(assignmentActions({ status: 'available' }, null, can(['it.view']))).toEqual([])
    expect(assignmentActions({ status: 'reserved' }, { issued_at: null, returned_at: null }, can(['it.assign']))).toEqual([
      { key: 'issue', label: 'Issue' },
      { key: 'cancel', label: 'Cancel reservation' },
    ])
    expect(assignmentActions({ status: 'reserved' }, { issued_at: null, returned_at: null }, can(['it.complete']))).toEqual([
      { key: 'issue', label: 'Issue' },
    ])
    expect(assignmentActions({ status: 'assigned' }, { issued_at: 'x', returned_at: null }, can(['it.complete']))).toEqual([
      { key: 'return', label: 'Return' },
    ])
    expect(assignmentActions({ status: 'damaged' }, null, can(['it.assign']))).toEqual([])
  })
})

describe('itRequestInput / parseSystems', () => {
  it('needs a person and a title; systems are a comma list', () => {
    expect(itRequestInput.safeParse({ personId: 'p', title: 'Laptop setup', systems: 'email, vpn', dueDate: '' }).success).toBe(true)
    expect(itRequestInput.safeParse({ personId: '', title: 'Laptop setup', systems: '', dueDate: '' }).success).toBe(false)
    expect(parseSystems(' email, vpn ,, ')).toEqual(['email', 'vpn'])
  })
})

describe('itRequestActions', () => {
  const can = (caps: string[]) => (cap: string) => caps.includes(cap)
  it('offers the next moves per status and capability', () => {
    expect(itRequestActions('open', can(['it.assign'])).map((a) => a.to)).toEqual(['in_progress', 'blocked', 'done', 'cancelled'])
    expect(itRequestActions('open', can(['it.complete'])).map((a) => a.to)).toEqual(['done'])
    expect(itRequestActions('blocked', can(['it.assign'])).map((a) => a.to)).toEqual(['in_progress', 'done', 'cancelled'])
    expect(itRequestActions('done', can(['it.assign']))).toEqual([])
    expect(assetStatusLabel('assigned')).toBe('Assigned')
  })
})

describe('the holding pool and the starter kit (plan 049)', () => {
  it('names the pool and a company on an asset', () => {
    expect(ownerLabel(null, { c1: 'Snowball' })).toBe('Holding pool')
    expect(ownerLabel('c1', { c1: 'Snowball' })).toBe('Snowball')
    expect(ownerLabel('cx', { c1: 'Snowball' })).toBe('Company')
  })
  it('reads the kit items off a request and counts what is issued', () => {
    const items = kitItems([{ item: 'Laptop', issued_at: '2026-01-01T00:00:00Z', asset_id: 'a1' }, { item: 'Badge', issued_at: null, asset_id: null }, 'junk'])
    expect(items).toEqual([
      { item: 'Laptop', issued_at: '2026-01-01T00:00:00Z', asset_id: 'a1' },
      { item: 'Badge', issued_at: null, asset_id: null },
    ])
    expect(kitProgress(items)).toEqual({ issued: 1, total: 2 })
    expect(kitItems(null)).toEqual([])
  })
  it('keeps a kit list tidy: trimmed, deduplicated, at most 40', () => {
    expect(tidyKit([' Laptop ', 'Badge', 'laptop', '', 'Badge'])).toEqual(['Laptop', 'Badge'])
    expect(tidyKit(Array.from({ length: 45 }, (_, i) => `Item ${i}`))).toHaveLength(40)
  })
})

describe('assetInput with every column the sheets use', () => {
  const base = {
    assetTag: 'A085',
    typeKey: 'laptop',
    model: 'Dell Vostro',
    serialNumber: '',
    locationId: '',
    note: '',
  }

  it('takes ред. бр. and Инв. бр. when a company keeps them', () => {
    const parsed = assetInput.safeParse({ ...base, ordinal: '53', inventoryNumber: '121' })
    expect(parsed.success).toBe(true)
    if (parsed.success) expect(parsed.data).toMatchObject({ ordinal: 53, inventoryNumber: '121' })
  })

  it('leaves them empty for a company that keeps neither', () => {
    const parsed = assetInput.safeParse({ ...base, ordinal: '', inventoryNumber: '' })
    expect(parsed.success).toBe(true)
    if (parsed.success) expect(parsed.data).toMatchObject({ ordinal: null, inventoryNumber: null })
  })

  it('refuses a ред. бр. that is not a number', () => {
    const parsed = assetInput.safeParse({ ...base, ordinal: 'fifty', inventoryNumber: '' })
    expect(parsed.success).toBe(false)
  })
})

describe('returnActions', () => {
  const ret: EquipmentReturn = {
    id: 'r1', status: 'awaiting_hr', person_id: 'p1', hr_person_id: 'hr1',
    decline_reason: null, signed_by_person_at: '2026-09-17', signed_by_hr_at: null,
  }

  it('lets the named HR person decide, and nothing else', () => {
    expect(returnActions(ret, 'hr1')).toEqual([
      { key: 'accept', label: 'Accept the return' },
      { key: 'decline', label: 'Not accepted' },
    ])
  })

  it('lets the person take it back while HR has not looked', () => {
    expect(returnActions(ret, 'p1')).toEqual([{ key: 'cancel', label: 'Cancel the return' }])
  })

  it('offers a bystander nothing', () => {
    expect(returnActions(ret, 'someone-else')).toEqual([])
    expect(returnActions(ret, null)).toEqual([])
  })

  it('offers nothing once it is settled', () => {
    for (const status of ['accepted', 'declined', 'cancelled'] as const) {
      expect(returnActions({ ...ret, status }, 'hr1')).toEqual([])
      expect(returnActions({ ...ret, status }, 'p1')).toEqual([])
    }
  })
})

describe('returnStatusLine', () => {
  const base: EquipmentReturn = {
    id: 'r1', status: 'awaiting_hr', person_id: 'p1', hr_person_id: 'hr1',
    decline_reason: null, signed_by_person_at: null, signed_by_hr_at: null,
  }

  it('names who it is waiting on', () => {
    expect(returnStatusLine(base, 'Ana')).toBe('Waiting for Ana to accept it.')
  })

  it('says both names are on it once accepted', () => {
    expect(returnStatusLine({ ...base, status: 'accepted' }, 'Ana')).toBe('Accepted by Ana. Signed by both of you.')
  })

  it('gives the reason it was refused', () => {
    expect(returnStatusLine({ ...base, status: 'declined', decline_reason: 'Keep it until Friday' }, 'Ana'))
      .toBe('Not accepted — Keep it until Friday')
  })

  it('copes with a refusal that carries no reason', () => {
    expect(returnStatusLine({ ...base, status: 'declined' }, 'Ana')).toBe('Not accepted.')
  })
})
