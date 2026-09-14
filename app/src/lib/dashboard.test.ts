import { describe, expect, it } from 'vitest'
import {
  applicantsInProgress,
  awayToday,
  inDaysLabel,
  openPositions,
  payrollLabel,
  pipelineCounts,
  recentApplicants,
  shoutoutLine,
  stageLabel,
  type ApplicationLite,
  type JobLite,
} from './dashboard'

const app = (over: Partial<ApplicationLite>): ApplicationLite => ({
  id: 'a',
  job_id: 'j1',
  stage_key: 'new',
  received_at: '2026-09-10T10:00:00Z',
  candidate: { full_name: 'Cand' },
  job: { title: 'Role', company: { name: 'Synami' } },
  ...over,
})

describe('dashboard', () => {
  it('counts applications per live stage in pipeline order, zero for empty stages', () => {
    const counts = pipelineCounts([
      app({ id: '1', stage_key: 'new' }),
      app({ id: '2', stage_key: 'interview' }),
      app({ id: '3', stage_key: 'interview' }),
      app({ id: '4', stage_key: 'withdrawn' }),
    ])
    expect(counts.map((c) => [c.key, c.count])).toEqual([
      ['new', 1],
      ['screening', 0],
      ['interview', 2],
      ['offer', 0],
      ['hired', 0],
      ['rejected', 0],
    ])
    expect(counts[2]?.label).toBe('Interview')
  })

  it('applicants in progress excludes hired, rejected and withdrawn', () => {
    expect(
      applicantsInProgress([
        app({ id: '1', stage_key: 'new' }),
        app({ id: '2', stage_key: 'offer' }),
        app({ id: '3', stage_key: 'hired' }),
        app({ id: '4', stage_key: 'rejected' }),
        app({ id: '5', stage_key: 'withdrawn' }),
      ]),
    ).toBe(2)
  })

  it('open positions are roles being hired (ready or open) with their live applicant count, headcount from the request', () => {
    const jobs: JobLite[] = [
      { id: 'j1', title: 'Designer', status: 'open', company: { name: 'Synami' }, request: { headcount: 2 } },
      { id: 'j2', title: 'Closed', status: 'closed', company: { name: 'Synami' }, request: null },
      { id: 'j3', title: 'Ready', status: 'ready', company: { name: 'Praedium' }, request: null },
      { id: 'j4', title: 'Paused', status: 'on_hold', company: { name: 'Praedium' }, request: null },
    ]
    const rows = openPositions(jobs, [
      app({ id: '1', job_id: 'j1' }),
      app({ id: '2', job_id: 'j1', stage_key: 'rejected' }),
      app({ id: '3', job_id: 'j2' }),
    ])
    expect(rows).toEqual([
      { id: 'j1', title: 'Designer', company: 'Synami', headcount: 2, applicants: 1 },
      { id: 'j3', title: 'Ready', company: 'Praedium', headcount: 1, applicants: 0 },
    ])
  })

  it('recent applicants are the newest first, capped', () => {
    const rows = recentApplicants(
      [
        app({ id: 'old', received_at: '2026-09-01T00:00:00Z' }),
        app({ id: 'new', received_at: '2026-09-12T00:00:00Z' }),
        app({ id: 'mid', received_at: '2026-09-05T00:00:00Z' }),
      ],
      2,
    )
    expect(rows.map((r) => r.id)).toEqual(['new', 'mid'])
    expect(rows[0]).toMatchObject({ name: 'Cand', position: 'Role', stage: 'new' })
  })

  it('away today lists approved leave covering today, with the last day', () => {
    const rows = awayToday(
      [
        { id: '1', status: 'approved', start_date: '2026-09-14', end_date: '2026-09-16', leave_type_key: 'annual', person: { full_name: 'Ana' } },
        { id: '2', status: 'pending', start_date: '2026-09-14', end_date: '2026-09-16', leave_type_key: 'annual', person: { full_name: 'Ben' } },
        { id: '3', status: 'approved', start_date: '2026-09-16', end_date: '2026-09-18', leave_type_key: 'sick', person: { full_name: 'Cy' } },
        { id: '4', status: 'approved', start_date: '2026-09-15', end_date: '2026-09-15', leave_type_key: 'sick', person: { full_name: 'Di' } },
      ],
      '2026-09-15',
    )
    expect(rows.map((r) => r.name)).toEqual(['Ana', 'Di'])
    expect(rows[0]).toMatchObject({ type: 'annual', until: '2026-09-16', backOn: false })
    expect(rows[1]?.backOn).toBe(true)
  })

  it('labels stages as the pipeline does, withdrawn included', () => {
    expect(stageLabel('new')).toBe('Applied')
    expect(stageLabel('withdrawn')).toBe('Withdrawn')
  })

  it('labels days until', () => {
    expect(inDaysLabel(0)).toBe('Today')
    expect(inDaysLabel(1)).toBe('Tomorrow')
    expect(inDaysLabel(5)).toBe('In 5 days')
  })

  it('picks a stable shoutout line per person', () => {
    expect(shoutoutLine('abc')).toBe(shoutoutLine('abc'))
    expect(shoutoutLine('abc')).toMatch(/\w/)
  })

  it('labels the last payroll with currency, period end and total', () => {
    expect(payrollLabel({ company_name: 'Synami', period_start: '2026-08-01', period_end: '2026-08-31', currency: 'EUR', total: 12345.5, people: 4, status: 'approved' })).toEqual({
      value: '12,345.50 EUR',
      sub: 'Synami · to 31 Aug 2026 · 4 people',
    })
  })
})
