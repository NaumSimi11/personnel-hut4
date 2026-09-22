import { describe, expect, it } from 'vitest'
import { NOT_RESPONDING_FILTER, applicantRows, openingRows, type ApplicantLite, type OpeningJobLite } from './hiringTabs'

const jobs: OpeningJobLite[] = [
  { id: 'j1', title: 'Designer', status: 'open', company_id: 'A', company: { name: 'Synami' }, request: { headcount: 2, manager: { full_name: 'Mia Manager' } } },
  { id: 'j2', title: 'Analyst', status: 'closed', company_id: 'A', company: { name: 'Synami' }, request: null },
  { id: 'j3', title: 'Engineer', status: 'on_hold', company_id: 'B', company: { name: 'Praedium' }, request: { headcount: 1, manager: null } },
  { id: 'j4', title: 'Draft role', status: 'draft', company_id: 'B', company: { name: 'Praedium' }, request: null },
]
const apps = [
  { id: 'a1', job_id: 'j1', stage_key: 'new' },
  { id: 'a2', job_id: 'j1', stage_key: 'hired' },
  { id: 'a3', job_id: 'j1', stage_key: 'rejected' },
  { id: 'a4', job_id: 'j2', stage_key: 'interview' },
]

describe('hiring tabs', () => {
  it('openings: live statuses by default, counts in play and hired, labels and manager', () => {
    const rows = openingRows(jobs, apps, { companyId: '', status: 'live' })
    expect(rows.map((r) => r.id)).toEqual(['j1', 'j3'])
    expect(rows[0]).toMatchObject({ title: 'Designer', company: 'Synami', headcount: 2, inPlay: 1, hired: 1, manager: 'Mia Manager', statusLabel: 'Open', statusTone: 'green' })
    expect(rows[1]).toMatchObject({ headcount: 1, manager: null, statusLabel: 'On hold', statusTone: 'amber' })
  })

  it('openings: filters by company and by one status; all shows drafts and closed too', () => {
    expect(openingRows(jobs, apps, { companyId: 'B', status: 'live' }).map((r) => r.id)).toEqual(['j3'])
    expect(openingRows(jobs, apps, { companyId: '', status: 'closed' }).map((r) => r.id)).toEqual(['j2'])
    expect(openingRows(jobs, apps, { companyId: '', status: 'all' }).map((r) => r.id)).toEqual(['j1', 'j2', 'j3', 'j4'])
  })

  it('applicants: flat rows newest first, with stage filter and name / position search', () => {
    const list: ApplicantLite[] = [
      { id: 'a1', company_id: 'A', stage_key: 'new', received_at: '2026-09-01T00:00:00Z', next_action: null, next_action_due: null, candidate: { full_name: 'Ana Kova', email: 'ana@x.test' }, job: { id: 'j1', title: 'Designer', company: { name: 'Synami' } }, owner: null },
      { id: 'a2', company_id: 'A', stage_key: 'interview', received_at: '2026-09-10T00:00:00Z', next_action: 'Second interview', next_action_due: '2026-09-20', candidate: { full_name: 'Ben Ilic', email: null }, job: { id: 'j1', title: 'Designer', company: { name: 'Synami' } }, owner: { full_name: 'Mia Manager' } },
      { id: 'a3', company_id: 'B', stage_key: 'rejected', received_at: '2026-09-05T00:00:00Z', next_action: null, next_action_due: null, candidate: { full_name: 'Cy Dan', email: null }, job: { id: 'j3', title: 'Engineer', company: { name: 'Praedium' } }, owner: null },
    ]
    const all = applicantRows(list, { companyId: '', stage: 'all', search: '' })
    expect(all.map((r) => r.id)).toEqual(['a2', 'a3', 'a1'])
    expect(all[0]).toMatchObject({ name: 'Ben Ilic', position: 'Designer', company: 'Synami', stageLabel: 'Interview', owner: 'Mia Manager', nextAction: 'Second interview · due 20 Sep' })
    expect(applicantRows(list, { companyId: '', stage: 'live', search: '' }).map((r) => r.id)).toEqual(['a2', 'a1'])
    expect(applicantRows(list, { companyId: '', stage: 'rejected', search: '' }).map((r) => r.id)).toEqual(['a3'])
    expect(applicantRows(list, { companyId: 'B', stage: 'all', search: '' }).map((r) => r.id)).toEqual(['a3'])
    expect(applicantRows(list, { companyId: '', stage: 'all', search: 'engi' }).map((r) => r.id)).toEqual(['a3'])
    expect(applicantRows(list, { companyId: '', stage: 'all', search: 'ANA' }).map((r) => r.id)).toEqual(['a1'])
  })

  it('applicants: carries the sub-status, flags not responding and filters on it (plan 054)', () => {
    const today = '2026-09-21'
    const job = { id: 'j1', title: 'Designer', status: 'open', company: { name: 'Synami' } }
    const base = { company_id: 'A', next_action: null, next_action_due: null, owner: null, job }
    const list: ApplicantLite[] = [
      { ...base, id: 'q1', stage_key: 'new', sub_status_key: 'sourced', received_at: '2026-06-01T00:00:00Z', candidate: { full_name: 'Ana Kova', email: null, last_activity_at: '2026-06-02T00:00:00Z' } },
      { ...base, id: 'q2', stage_key: 'screening', sub_status_key: 'contacted', received_at: '2026-06-05T00:00:00Z', candidate: { full_name: 'Ben Ilic', email: null, last_activity_at: '2026-09-20T00:00:00Z' } },
      { ...base, id: 'q3', stage_key: 'screening', sub_status_key: 'qualified', received_at: '2026-06-03T00:00:00Z', candidate: { full_name: 'Cy Dan', email: null, last_activity_at: '2026-06-03T00:00:00Z' } },
      { ...base, id: 'q4', stage_key: 'interview', received_at: '2026-06-04T00:00:00Z', candidate: { full_name: 'Di Eno', email: null } },
    ]
    const all = applicantRows(list, { companyId: '', stage: 'all', search: '', today })
    expect(all.map((r) => [r.id, r.subStatusKey, r.notResponding])).toEqual([
      ['q2', 'contacted', false],
      ['q4', null, false],
      ['q3', 'qualified', false],
      ['q1', 'sourced', true],
    ])
    expect(applicantRows(list, { companyId: '', stage: NOT_RESPONDING_FILTER, search: '', today }).map((r) => r.id)).toEqual(['q1'])
    expect(applicantRows(list, { companyId: '', stage: NOT_RESPONDING_FILTER, search: 'ben', today })).toEqual([])
  })
})
