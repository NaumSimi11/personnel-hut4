import { describe, expect, it } from 'vitest'
import { assetInput, assetStatusLabel, assignmentActions, itRequestActions, itRequestInput, parseSystems } from './equipment'

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
