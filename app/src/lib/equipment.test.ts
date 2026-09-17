import { describe, expect, it } from 'vitest'
import { assetInput, assetStatusLabel, assignmentActions, itRequestActions, itRequestInput, kitItems, kitProgress, ownerLabel, parseSystems, handoverActions, handoverSide, handoverStatusLine, tidyKit, type Handover } from './equipment'

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

describe('handoverSide', () => {
  const back: Handover = {
    id: 'r1', kind: 'return', status: 'awaiting', started_by: 'p1', counterparty_id: 'hr1',
    from_person_id: 'p1', to_person_id: null,
    decline_reason: null, signed_by_starter_at: null, signed_by_counterparty_at: null,
  }
  const out: Handover = { ...back, kind: 'issue', started_by: 'it1', counterparty_id: 'p2', from_person_id: null, to_person_id: 'p2' }

  it('reads off where you stand, not which button was pressed', () => {
    expect(handoverSide(back, 'p1')).toBe('returning')
    expect(handoverSide(back, 'hr1')).toBe('receivingForCompany')
    expect(handoverSide(out, 'p2')).toBe('receiving')
    expect(handoverSide(out, 'it1')).toBe('handingOver')
  })

  it('gives the same answer for a recall as for a return, because it is one', () => {
    // HR asked for it back: they started it, the holder is the counterparty.
    const recall: Handover = { ...back, started_by: 'hr1', counterparty_id: 'p1' }
    expect(handoverSide(recall, 'p1')).toBe('returning')
    expect(handoverSide(recall, 'hr1')).toBe('receivingForCompany')
  })
})

describe('handoverActions', () => {
  const back: Handover = {
    id: 'r1', kind: 'return', status: 'awaiting', started_by: 'p1', counterparty_id: 'hr1',
    from_person_id: 'p1', to_person_id: null,
    decline_reason: null, signed_by_starter_at: '2026-09-17', signed_by_counterparty_at: null,
  }
  const out: Handover = { ...back, kind: 'issue', started_by: 'it1', counterparty_id: 'p2', from_person_id: null, to_person_id: 'p2' }

  it('asks HR to accept a return', () => {
    expect(handoverActions(back, 'hr1')).toEqual([
      { key: 'accept', label: 'Accept the return' },
      { key: 'decline', label: 'Not accepted' },
    ])
  })

  it('asks the holder to confirm, not to accept, when HR wants it back', () => {
    const recall: Handover = { ...back, started_by: 'hr1', counterparty_id: 'p1' }
    expect(handoverActions(recall, 'p1')).toEqual([
      { key: 'accept', label: 'Confirm I handed it over' },
      { key: 'decline', label: 'I still have it' },
    ])
  })

  it('asks the receiver to accept when something is handed out', () => {
    expect(handoverActions(out, 'p2')).toEqual([
      { key: 'accept', label: 'Accept it' },
      { key: 'decline', label: 'I did not get it' },
    ])
    expect(handoverActions(out, 'it1')).toEqual([{ key: 'cancel', label: 'Withdraw' }])
  })

  it('lets whoever started it take it back while the other has not looked', () => {
    expect(handoverActions(back, 'p1')).toEqual([{ key: 'cancel', label: 'Cancel the return' }])
  })

  it('offers a bystander nothing', () => {
    expect(handoverActions(back, 'someone-else')).toEqual([])
    expect(handoverActions(back, null)).toEqual([])
  })

  it('offers nothing once it is settled', () => {
    for (const status of ['accepted', 'declined', 'cancelled'] as const) {
      expect(handoverActions({ ...back, status }, 'hr1')).toEqual([])
      expect(handoverActions({ ...back, status }, 'p1')).toEqual([])
    }
  })
})

describe('handoverStatusLine', () => {
  const base: Handover = {
    id: 'r1', kind: 'return', status: 'awaiting', started_by: 'p1', counterparty_id: 'hr1',
    from_person_id: 'p1', to_person_id: null,
    decline_reason: null, signed_by_starter_at: null, signed_by_counterparty_at: null,
  }
  const names = { starter: 'Bob', counterparty: 'Ana' }

  it('names who it is waiting on', () => {
    expect(handoverStatusLine(base, 'p1', names)).toBe('Waiting for Ana to sign it.')
  })

  it('addresses the one who has to sign directly', () => {
    expect(handoverStatusLine(base, 'hr1', names)).toBe('Waiting for you to sign it.')
  })

  it('says both names are on it once a return is accepted', () => {
    expect(handoverStatusLine({ ...base, status: 'accepted' }, 'p1', names))
      .toBe('Accepted by Ana. Signed by both of you.')
  })

  it('reads the other way round for something handed out', () => {
    expect(handoverStatusLine({ ...base, kind: 'issue', status: 'accepted' }, 'p1', names))
      .toBe('Ana signed for it.')
  })

  it('gives the reason it was refused', () => {
    expect(handoverStatusLine({ ...base, status: 'declined', decline_reason: 'Keep it until Friday' }, 'p1', names))
      .toBe('Not accepted — Keep it until Friday')
  })

  it('copes with a refusal that carries no reason', () => {
    expect(handoverStatusLine({ ...base, status: 'declined' }, 'p1', names)).toBe('Not accepted.')
  })

  it('says who withdrew it', () => {
    expect(handoverStatusLine({ ...base, status: 'cancelled' }, 'p1', names)).toBe('You withdrew this.')
    expect(handoverStatusLine({ ...base, status: 'cancelled' }, 'hr1', names)).toBe('Bob withdrew this.')
  })
})
