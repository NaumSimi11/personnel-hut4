import { describe, expect, it } from 'vitest'
import {
  EMPTY_SNAPSHOT,
  applicantsInProgress,
  awayToday,
  dashboardSections,
  inDaysLabel,
  openPositions,
  payrollLabel,
  pipelineCounts,
  recentApplicants,
  shoutoutLine,
  stageLabel,
  statTiles,
  type ApplicationLite,
  type JobLite,
  type PayrollFact,
} from './dashboard'

/** A viewer holding exactly the listed capabilities, anywhere. */
const viewerWith = (...caps: string[]) => ({ canAnywhere: (cap: string) => caps.includes(cap) })
const PAYROLL: PayrollFact = { company_name: 'Synami', period_start: '2026-08-01', period_end: '2026-08-31', currency: 'EUR', total: 1000, people: 2, status: 'approved' }

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

  it('shows each stat only to a viewer who may already see that data', () => {
    const snapshot = { ...EMPTY_SNAPSHOT, active: 12, starting: 1 }
    const input = { snapshot, away: [{ id: '1', name: 'Ana', type: 'annual', until: '2026-09-16', backOn: false }], applications: [app({ id: '1' })], requestsToDecide: 3 }

    expect(statTiles({ ...input, viewer: viewerWith() }).map((t) => t.key)).toEqual([])
    expect(statTiles({ ...input, viewer: viewerWith('people.view') }).map((t) => t.key)).toEqual(['active'])
    expect(statTiles({ ...input, viewer: viewerWith('leave.approve') }).map((t) => t.key)).toEqual(['away'])
    expect(statTiles({ ...input, viewer: viewerWith('candidates.view') }).map((t) => t.key)).toEqual(['applicants'])
    expect(statTiles({ ...input, viewer: viewerWith('jobs.approve') }).map((t) => t.key)).toEqual(['requests'])
  })

  it('states the headline numbers and keeps the payroll tile on what the database returned', () => {
    const snapshot = { ...EMPTY_SNAPSHOT, active: 12, starting: 1, payroll: [PAYROLL] }
    const all = viewerWith('people.view', 'leave.view', 'candidates.view', 'jobs.approve')
    const tiles = statTiles({ snapshot, away: [], applications: [app({ id: '1' }), app({ id: '2', stage_key: 'hired' })], requestsToDecide: 3, viewer: all })
    expect(tiles.map((t) => [t.key, t.value])).toEqual([
      ['active', 12],
      ['away', 0],
      ['applicants', 1],
      ['requests', 3],
      ['payroll', '1,000 EUR'],
    ])
    expect(tiles[0]?.sub).toBe('1 starting soon')
    // No payroll row came back (no payroll.summary anywhere) → no tile, whatever the viewer claims.
    expect(statTiles({ snapshot: { ...snapshot, payroll: [] }, away: [], applications: [], requestsToDecide: 0, viewer: all }).map((t) => t.key)).not.toContain('payroll')
  })

  it('opens each dashboard section to the capability that governs its data', () => {
    expect(dashboardSections(viewerWith())).toEqual({ team: false, pipeline: false, openings: false, recruitment: false, away: false })
    expect(dashboardSections(viewerWith('people.view'))).toMatchObject({ team: true, recruitment: false })
    expect(dashboardSections(viewerWith('candidates.view'))).toMatchObject({ pipeline: true, openings: false, recruitment: true })
    expect(dashboardSections(viewerWith('jobs.view'))).toMatchObject({ pipeline: false, openings: true, recruitment: true })
    expect(dashboardSections(viewerWith('leave.view'))).toMatchObject({ away: true })
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
