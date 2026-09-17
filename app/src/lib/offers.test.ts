import { describe, expect, it } from 'vitest'
import { OFFER_STAGES, offerActions, offerStage, offerTermsInput, termsFromOffer } from './offers'

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

  it('lets a reviewer submit a draft', () => {
    expect(offerActions({ status: 'draft', created_by: me }, me, can(['candidates.review']))).toEqual([
      { to: 'in_approval', label: 'Submit for approval' },
      { to: 'withdrawn', label: 'Withdraw offer' },
    ])
  })

  it('lets whoever holds offer.approve approve, including the person who drafted it', () => {
    // The holding decided one person may carry an offer the whole way. Who
    // approved is still recorded on the offer, so author-approved-their-own is
    // visible in the record rather than prevented.
    expect(offerActions({ status: 'in_approval', created_by: me }, me, can(['offer.approve']))).toEqual([
      { to: 'approved', label: 'Approve' },
      { to: 'draft', label: 'Send back' },
    ])
    expect(offerActions({ status: 'in_approval', created_by: 'other' }, me, can(['offer.approve']))).toEqual([
      { to: 'approved', label: 'Approve' },
      { to: 'draft', label: 'Send back' },
    ])
  })

  it('still offers nothing but a withdrawal to someone who cannot approve', () => {
    // Approving takes offer.approve; candidates.review alone is not enough.
    expect(offerActions({ status: 'in_approval', created_by: me }, me, can(['candidates.review']))).toEqual([
      { to: 'withdrawn', label: 'Withdraw offer' },
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

describe('OFFER_STAGES', () => {
  it('names the chain an offer walks, in order', () => {
    expect(OFFER_STAGES.map((s) => s.id)).toEqual([
      'draft',
      'in_approval',
      'approved',
      'extended',
      'accepted',
    ])
  })

  it('numbers them so the card reads like the job strip', () => {
    expect(OFFER_STAGES.map((s) => s.number)).toEqual(['01', '02', '03', '04', '05'])
  })

  it('labels them in words, not database keys', () => {
    expect(OFFER_STAGES.map((s) => s.label)).toEqual([
      'Drafted',
      'In approval',
      'Approved',
      'Extended',
      'Accepted',
    ])
  })
})

describe('offerStage', () => {
  it('places a live offer on the chain', () => {
    expect(offerStage('draft')).toBe('draft')
    expect(offerStage('in_approval')).toBe('in_approval')
    expect(offerStage('approved')).toBe('approved')
    expect(offerStage('extended')).toBe('extended')
    expect(offerStage('accepted')).toBe('accepted')
  })

  it('shows no chain for an offer that ended off it', () => {
    // Withdrawn and declined leave the chain rather than finish it, and the
    // card already states which; drawing a half-lit strip would only mislead.
    expect(offerStage('withdrawn')).toBeNull()
    expect(offerStage('declined')).toBeNull()
  })

  it('shows no chain for a status it does not recognise', () => {
    expect(offerStage('something_new')).toBeNull()
  })
})
