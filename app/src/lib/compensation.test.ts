import { describe, expect, it } from 'vitest'
import { annualise, compensationActions, currentRecord, formatAmount, proposalInput, recordLabel, todayDb } from './compensation'

describe('proposalInput', () => {
  it('coerces the amount, upper-cases the currency and requires a date', () => {
    const ok = proposalInput.safeParse({ amount: '66000', currency: 'eur', payBasisKey: 'annual', effectiveDate: '2026-10-01', note: '' })
    expect(ok.success).toBe(true)
    if (ok.success) expect(ok.data).toMatchObject({ amount: 66000, currency: 'EUR' })
    expect(proposalInput.safeParse({ amount: '0', currency: 'EUR', payBasisKey: 'annual', effectiveDate: '2026-10-01', note: '' }).success).toBe(false)
    expect(proposalInput.safeParse({ amount: '1', currency: 'euros', payBasisKey: 'annual', effectiveDate: '2026-10-01', note: '' }).success).toBe(false)
  })
})

describe('annualise', () => {
  it('uses the standard working-year multipliers', () => {
    expect(annualise(5000, 'monthly')).toBe(60000)
    expect(annualise(250, 'daily')).toBe(65000)
    expect(annualise(30, 'hourly')).toBe(62400)
    expect(annualise(70000, 'annual')).toBe(70000)
  })
})

describe('formatAmount', () => {
  it('groups thousands and keeps the currency code', () => {
    expect(formatAmount(66000, 'EUR')).toBe('66,000 EUR')
    expect(formatAmount(1234.5, 'MKD')).toBe('1,234.50 MKD')
  })
})

describe('currentRecord', () => {
  const records = [
    { status: 'superseded', effective_date: '2024-01-01', end_date: '2026-09-30' },
    { status: 'approved', effective_date: '2026-10-01', end_date: null },
    { status: 'proposed', effective_date: '2027-01-01', end_date: null },
  ]
  it('is the approved record in force today', () => {
    expect(currentRecord(records, '2026-10-15')?.effective_date).toBe('2026-10-01')
    expect(currentRecord(records, '2026-09-15')).toBeNull()
  })
})

describe('compensationActions', () => {
  const can = (caps: string[]) => (cap: string) => caps.includes(cap)
  it('offers approve/reject only to an approver who did not propose', () => {
    expect(compensationActions({ status: 'proposed', proposed_by: 'me' }, 'me', can(['salary.approve']))).toEqual([])
    expect(compensationActions({ status: 'proposed', proposed_by: 'other' }, 'me', can(['salary.approve']))).toEqual([
      { to: 'approved', label: 'Approve' },
      { to: 'rejected', label: 'Reject' },
    ])
    expect(compensationActions({ status: 'approved', proposed_by: 'other' }, 'me', can(['salary.approve']))).toEqual([])
  })
})

describe('todayDb', () => {
  it("is the UTC calendar date — the database's current_date — whatever the browser's zone", () => {
    expect(todayDb(new Date(Date.UTC(2026, 8, 11, 23, 30)))).toBe('2026-09-11')
    expect(todayDb(new Date(Date.UTC(2026, 8, 12, 0, 5)))).toBe('2026-09-12')
  })
})

describe('recordLabel', () => {
  const today = '2026-09-12'
  it('reads the state from the dates, since a closed record stays approved', () => {
    expect(recordLabel({ status: 'approved', effective_date: '2024-01-01', end_date: '2025-12-31' }, today)).toBe('Superseded')
    expect(recordLabel({ status: 'approved', effective_date: '2026-01-01', end_date: null }, today)).toBe('Current')
    expect(recordLabel({ status: 'approved', effective_date: '2026-01-01', end_date: '2026-12-31' }, today)).toBe('Current')
    expect(recordLabel({ status: 'approved', effective_date: '2027-01-01', end_date: null }, today)).toBe('Scheduled')
    expect(recordLabel({ status: 'rejected', effective_date: '2026-01-01', end_date: null }, today)).toBe('Rejected')
    expect(recordLabel({ status: 'proposed', effective_date: '2026-01-01', end_date: null }, today)).toBe('Awaiting decision')
  })
})
