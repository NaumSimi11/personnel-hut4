import { describe, expect, it } from 'vitest'
import { offerState, salaryLine, type CandidateOffer } from './offerApi'

const offer: CandidateOffer = {
  status: 'extended', candidate: 'Oli', job: 'Designer', company: 'Hut4', salary: '42000', currency: 'EUR', pay_basis: 'Annual',
  employment_type: 'Full-time', start_date: '2027-01-04', expires_on: '2026-11-20', expired: false, answered_at: null,
}

describe('candidate offer page', () => {
  it('can be answered while sent and not expired', () => {
    expect(offerState(offer)).toBe('answer')
    expect(offerState({ ...offer, expired: true })).toBe('expired')
    expect(offerState({ ...offer, status: 'accepted' })).toBe('accepted')
    expect(offerState({ ...offer, status: 'declined' })).toBe('declined')
  })
  it('writes the salary plainly', () => {
    expect(salaryLine(offer)).toBe('42,000 EUR (annual)')
    expect(salaryLine({ ...offer, salary: null })).toBeNull()
  })
})
