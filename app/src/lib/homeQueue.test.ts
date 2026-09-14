import { describe, expect, it } from 'vitest'
import {
  compensationToRows,
  documentReviewsToRows,
  itRequestsToRows,
  leaveToRows,
  hiringManagerToRows,
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

  it('offers leave requests and cancellation asks where the viewer may approve, never their own', () => {
    const base = { start_date: '2027-03-01', end_date: '2027-03-03', working_days: 3, leave_type_key: 'annual', status: 'pending', cancellation_requested_at: null, cancellation_declined_at: null, person: { full_name: 'Ana' }, company: { name: 'Praedium' } }
    const rows = leaveToRows(
      [
        { ...base, id: 'l1', person_id: 'p1', company_id: 'A' },
        { ...base, id: 'l2', person_id: 'me', company_id: 'A' },
        { ...base, id: 'l3', person_id: 'p3', company_id: 'B' },
        { ...base, id: 'l4', person_id: 'p4', company_id: 'A', status: 'approved', cancellation_requested_at: '2027-02-01T00:00:00Z' },
        { ...base, id: 'l5', person_id: 'p5', company_id: 'A', status: 'approved', cancellation_requested_at: '2027-02-01T00:00:00Z', cancellation_declined_at: '2027-02-02T00:00:00Z' },
        { ...base, id: 'l6', person_id: 'p6', company_id: 'A', status: 'approved' },
      ],
      viewer,
    )
    expect(rows.map((r) => r.id)).toEqual(['leave-l1', 'leave-l4'])
    expect(rows[0]?.title).toBe('Leave: Ana')
    expect(rows[0]?.sub).toBe('Praedium · annual 2027-03-01 → 2027-03-03 (3 days) awaiting your decision')
    expect(rows[1]?.sub).toBe('Praedium · asks to cancel approved leave 2027-03-01 → 2027-03-03')
    expect(rows[0]?.to).toEqual({ name: 'leave', query: { tab: 'requests' } })
  })

  it('tells the hiring manager where their request stands, only where they may open it', () => {
    const base = { title: 'Dispatcher', target_start_date: '2027-01-11', requester: { full_name: 'Fiona' }, company: { name: 'Praedium' }, jobs: [] as { id: string; status: string }[] }
    const rows = hiringManagerToRows(
      [
        { ...base, id: 'h1', company_id: 'A', status: 'submitted' },
        { ...base, id: 'h2', company_id: 'A', status: 'approved' },
        { ...base, id: 'h3', company_id: 'A', status: 'approved', jobs: [{ id: 'j3', status: 'open' }] },
        { ...base, id: 'h4', company_id: 'A', status: 'rejected' },
        { ...base, id: 'h5', company_id: 'B', status: 'submitted' },
      ],
      viewer,
    )
    expect(rows.map((r) => r.id)).toEqual(['manager-h1', 'manager-h2'])
    expect(rows[0]?.title).toBe('Hiring manager: Dispatcher')
    expect(rows[0]?.sub).toBe('Praedium · requested by Fiona · awaiting approval — recruitment has not started · target start 2027-01-11')
    expect(rows[0]?.actionLabel).toBe('View request')
    expect(rows[1]?.sub).toBe('Praedium · approved — recruitment can proceed · target start 2027-01-11')
    expect(rows[1]?.actionLabel).toBe('Prepare the role')
  })
})
