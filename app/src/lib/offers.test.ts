import { describe, expect, it } from 'vitest'
import { offerActions, offerTermsInput, termsFromOffer } from './offers'

describe('offerTermsInput', () => {
  it('accepts salary, currency, pay basis, start date and employment type', () => {
    const parsed = offerTermsInput.safeParse({
      salary: '52000',
      currency: 'eur',
      payBasis: 'annual',
      startDate: '2026-11-02',
      employmentType: 'full_time',
      notes: ' Laptop provided ',
    })
    expect(parsed.success).toBe(true)
    if (parsed.success) {
      expect(parsed.data).toEqual({
        salary: 52000,
        currency: 'EUR',
        payBasis: 'annual',
        startDate: '2026-11-02',
        employmentType: 'full_time',
        notes: 'Laptop provided',
      })
    }
  })

  it('rejects a non-positive salary, a bad currency code and a missing start date', () => {
    const bad = offerTermsInput.safeParse({ salary: '0', currency: 'EUR', payBasis: 'annual', startDate: '2026-11-02', employmentType: 'full_time', notes: '' })
    expect(bad.success).toBe(false)
    if (!bad.success) expect(bad.error.issues[0]?.message).toBe('Enter the salary amount.')
    expect(offerTermsInput.safeParse({ salary: '1', currency: 'euros', payBasis: 'annual', startDate: '2026-11-02', employmentType: 'full_time', notes: '' }).success).toBe(false)
    expect(offerTermsInput.safeParse({ salary: '1', currency: 'EUR', payBasis: 'annual', startDate: '', employmentType: 'full_time', notes: '' }).success).toBe(false)
  })
})

describe('termsFromOffer', () => {
  it('maps stored terms back to the form, tolerating missing keys', () => {
    expect(termsFromOffer({ salary: 52000, currency: 'EUR', pay_basis: 'annual', start_date: '2026-11-02' })).toEqual({
      salary: '52000',
      currency: 'EUR',
      payBasis: 'annual',
      startDate: '2026-11-02',
      employmentType: 'full_time',
      notes: '',
    })
    expect(termsFromOffer(null).salary).toBe('')
  })
})

describe('offerActions', () => {
  const me = 'p-me'
  const can = (caps: string[]) => (cap: string) => caps.includes(cap)

  it('lets a reviewer submit a draft, and approve only if they did not draft it', () => {
    expect(offerActions({ status: 'draft', created_by: me }, me, can(['candidates.review']))).toEqual([
      { to: 'in_approval', label: 'Submit for approval' },
      { to: 'withdrawn', label: 'Withdraw offer' },
    ])
    expect(offerActions({ status: 'in_approval', created_by: me }, me, can(['offer.approve']))).toEqual([])
    // The author waiting on approval can still withdraw — never stuck.
    expect(offerActions({ status: 'in_approval', created_by: me }, me, can(['candidates.review']))).toEqual([
      { to: 'withdrawn', label: 'Withdraw offer' },
    ])
    expect(offerActions({ status: 'in_approval', created_by: 'other' }, me, can(['offer.approve']))).toEqual([
      { to: 'approved', label: 'Approve' },
      { to: 'draft', label: 'Send back' },
    ])
  })

  it('walks approved → extended → accepted / declined, with withdraw available until then', () => {
    expect(offerActions({ status: 'approved', created_by: me }, me, can(['candidates.review']))).toEqual([
      { to: 'extended', label: 'Mark as extended' },
      { to: 'withdrawn', label: 'Withdraw offer' },
    ])
    expect(offerActions({ status: 'extended', created_by: me }, me, can(['candidates.review']))).toEqual([
      { to: 'accepted', label: 'Candidate accepted' },
      { to: 'declined', label: 'Candidate declined' },
      { to: 'withdrawn', label: 'Withdraw offer' },
    ])
    expect(offerActions({ status: 'accepted', created_by: me }, me, can(['candidates.review']))).toEqual([])
  })
})
