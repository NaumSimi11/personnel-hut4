import { describe, expect, it } from 'vitest'
import { approvalSummary, type ApprovalItem } from './myApprovals'

const base: ApprovalItem = {
  id: 't', subject_type: 'request', subject_id: 's', company: 'Hut4', position: 1, steps: 2, label: 'HR', title: 'Hiring request: Designer',
  created_at: '2026-11-12T00:00:00Z', as_delegate: false, detail: null,
}

describe('approvalSummary', () => {
  it('sums up a request with its band', () => {
    expect(approvalSummary({ ...base, detail: { requester: 'Hana', headcount: 2, budget: { min: 30000, max: 40000, currency: 'EUR' }, reason: 'Growth' } }))
      .toBe('requested by Hana · headcount 2 · band 30,000–40,000 EUR · Growth')
  })
  it('sums up an offer with its band note', () => {
    expect(approvalSummary({ ...base, subject_type: 'offer', detail: { terms: { salary: 45000, currency: 'EUR', start_date: '2027-01-04' }, band_note: 'Outside the band 30000–40000 EUR' } }))
      .toBe('45,000 EUR · starts 2027-01-04 · Outside the band 30000–40000 EUR')
  })
  it('copes with no detail', () => {
    expect(approvalSummary(base)).toBe('')
  })
})
