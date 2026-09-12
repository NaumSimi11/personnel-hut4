import { describe, expect, it } from 'vitest'
import {
  compensationToRows,
  documentReviewsToRows,
  itRequestsToRows,
  myRequestsToRows,
  payrollToRows,
  policiesToRows,
} from './homeQueue'

const viewer = { personId: 'me', can: (companyId: string, cap: string) => companyId === 'A' && cap !== 'none' }

describe('home queue converters', () => {
  it('offers compensation decisions only where the viewer may approve and did not propose', () => {
    const rows = compensationToRows(
      [
        { id: 'c1', proposed_by: 'other', period: { person_id: 'p1', company_id: 'A', person: { full_name: 'Ana' }, company: { name: 'Praedium' } } },
        { id: 'c2', proposed_by: 'me', period: { person_id: 'p2', company_id: 'A', person: { full_name: 'Ben' }, company: { name: 'Praedium' } } },
        { id: 'c3', proposed_by: 'other', period: { person_id: 'p3', company_id: 'B', person: { full_name: 'Cy' }, company: { name: 'Other' } } },
      ],
      viewer,
    )
    expect(rows.map((r) => r.title)).toEqual(['Compensation: Ana'])
    expect(rows[0]?.to).toEqual({ name: 'person', params: { personId: 'p1' } })
  })

  it('lists submitted document requests to review and open ones asked of me', () => {
    const review = documentReviewsToRows(
      [{ id: 'r1', person_id: 'p1', company_id: 'A', category_key: 'identification', person: { full_name: 'Ana' }, category: { label: 'Identification' } }],
      viewer,
    )
    expect(review[0]?.title).toBe('Document to review: Identification')
    const mine = myRequestsToRows([{ id: 'r2', category: { label: 'Identification' }, company: { name: 'Praedium' }, due_date: '2026-10-01' }])
    expect(mine[0]?.title).toBe('Upload: Identification')
    expect(mine[0]?.sub).toContain('due 2026-10-01')
  })

  it('lists policies not acknowledged at their current version', () => {
    const rows = policiesToRows(
      [
        { id: 'p1', title: 'Code of conduct', version: 2, company: { name: 'Praedium' } },
        { id: 'p2', title: 'Travel', version: 1, company: null },
      ],
      [{ policy_id: 'p1', version: 1 }, { policy_id: 'p2', version: 1 }],
    )
    expect(rows.map((r) => r.title)).toEqual(['Policy: Code of conduct'])
    expect(rows[0]?.sub).toContain('new version')
  })

  it('lists IT requests I can work and payroll periods I can approve but did not prepare', () => {
    const it = itRequestsToRows(
      [
        { id: 'i1', title: 'Laptop', status: 'open', company_id: 'A', assignee_id: null, person: { full_name: 'Ana' }, company: { name: 'Praedium' } },
        { id: 'i2', title: 'VPN', status: 'blocked', company_id: 'B', assignee_id: null, person: { full_name: 'Cy' }, company: { name: 'Other' } },
      ],
      viewer,
    )
    expect(it.map((r) => r.title)).toEqual(['IT request: Laptop'])
    const pay = payrollToRows(
      [
        { id: 'y1', company_id: 'A', period_start: '2026-09-01', period_end: '2026-09-30', currency: 'EUR', prepared_by: 'other', company: { name: 'Praedium' } },
        { id: 'y2', company_id: 'A', period_start: '2026-08-01', period_end: '2026-08-31', currency: 'EUR', prepared_by: 'me', company: { name: 'Praedium' } },
      ],
      viewer,
    )
    expect(pay.map((r) => r.title)).toEqual(['Payroll: 2026-09-01 → 2026-09-30 EUR'])
    expect(pay[0]?.to).toEqual({ name: 'company', params: { companyId: 'A' }, query: { tab: 'payroll' } })
  })
})
