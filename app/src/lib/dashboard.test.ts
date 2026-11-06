import { describe, expect, it } from 'vitest'
import {
  EMPTY_HIRING_SUMMARY,
  EMPTY_SNAPSHOT,
  applicantsInProgress,
  awayToday,
  dashboardSections,
  inDaysLabel,
  notRespondingCount,
  parseHiringSummary,
  openPositions,
  payrollLabel,
  pipelineCounts,
  recentApplicants,
  shoutoutLine,
  stageLabel,
  statTiles,
  type HiringSummary,
  type JobLite,
  type PayrollFact,
} from './dashboard'

/** A viewer holding exactly the listed capabilities, anywhere. */
const viewerWith = (...caps: string[]) => ({ canAnywhere: (cap: string) => caps.includes(cap) })
const PAYROLL: PayrollFact = { company_name: 'Synami', period_start: '2026-08-01', period_end: '2026-08-31', currency: 'EUR', total: 1000, people: 2, status: 'approved' }

/** One by_job row of hiring_summary; the count defaults to one application. */
const row = (job_id: string, stage_key: string, in_play = true, count = 1) => ({ job_id, stage_key, in_play, count, last_received_at: '2026-09-10T10:00:00Z' })
const summaryOf = (by_job: HiringSummary['by_job'], extra: Partial<HiringSummary> = {}): HiringSummary => ({ ...EMPTY_HIRING_SUMMARY, by_job, ...extra })

describe('dashboard', () => {
  it('counts applications per live stage in pipeline order, zero for empty stages', () => {
    const counts = pipelineCounts(
      summaryOf([row('j1', 'screening'), row('j1', 'interview', true, 2), row('j2', 'screening', false), row('j2', 'hired', false)]),
    )
    expect(counts.map((c) => [c.key, c.count])).toEqual([
      ['screening', 1],
      ['interview', 2],
      ['offer', 0],
      ['hired', 1],
    ])
    expect(counts[1]?.label).toBe('Interview')
    expect(counts[2]?.label).toBe('Offered')
  })

  it('applicants in progress counts only the ones still in play', () => {
    expect(
      applicantsInProgress(
        summaryOf([row('j1', 'screening'), row('j1', 'offer'), row('j1', 'hired', false), row('j1', 'interview', false)]),
      ),
    ).toBe(2)
    expect(applicantsInProgress(summaryOf([row('j1', 'screening', false)]))).toBe(0)
  })

  it('open positions are roles being hired (ready or open) with their live applicant count, headcount from the request', () => {
    const jobs: JobLite[] = [
      { id: 'j1', title: 'Designer', status: 'open', company: { name: 'Synami' }, request: { headcount: 2 } },
      { id: 'j2', title: 'Closed', status: 'closed', company: { name: 'Synami' }, request: null },
      { id: 'j3', title: 'Ready', status: 'ready', company: { name: 'Praedium' }, request: null },
      { id: 'j4', title: 'Paused', status: 'on_hold', company: { name: 'Praedium' }, request: null },
    ]
    const rows = openPositions(jobs, summaryOf([row('j1', 'screening'), row('j1', 'interview', false), row('j2', 'screening')]))
    expect(rows).toEqual([
      { id: 'j1', title: 'Designer', company: 'Synami', headcount: 2, applicants: 1, daysOpen: null },
      { id: 'j3', title: 'Ready', company: 'Praedium', headcount: 1, applicants: 0, daysOpen: null },
    ])
  })

  it('open positions carry how long they have been open, oldest first, the never-opened last', () => {
    const jobs: JobLite[] = [
      { id: 'young', title: 'Young', status: 'open', company: null, request: null, opened_at: '2026-09-20T09:00:00Z' },
      { id: 'ready', title: 'Ready', status: 'ready', company: null, request: null, opened_at: null },
      { id: 'old', title: 'Old', status: 'open', company: null, request: null, opened_at: '2026-06-01T09:00:00Z' },
    ]
    const rows = openPositions(jobs, EMPTY_HIRING_SUMMARY, '2026-09-24')
    expect(rows.map((r) => [r.id, r.daysOpen])).toEqual([['old', 115], ['young', 4], ['ready', null]])
  })

  it('recent applicants come shaped from the summary, capped', () => {
    const recent = (id: string, received_at: string) => ({ application_id: id, candidate_name: 'Cand', job_title: 'Role', company_name: 'Synami', stage_key: 'screening', received_at })
    const summary = summaryOf([], { recent: [recent('new', '2026-09-12T00:00:00Z'), recent('mid', '2026-09-05T00:00:00Z'), recent('old', '2026-09-01T00:00:00Z')] })
    const rows = recentApplicants(summary, 2)
    expect(rows.map((r) => r.id)).toEqual(['new', 'mid'])
    expect(rows[0]).toMatchObject({ name: 'Cand', position: 'Role', company: 'Synami', stage: 'screening', inPlay: true })
    expect(recentApplicants(summaryOf([], { recent: [{ ...recent('x', '2026-09-01T00:00:00Z'), candidate_name: null, job_title: null, company_name: null }] }))[0]).toMatchObject({ name: 'Candidate', position: '—', company: '—' })
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

  it('labels stages as the pipeline does, an unknown key as itself', () => {
    expect(stageLabel('screening')).toBe('Screening')
    expect(stageLabel('offer')).toBe('Offered')
    expect(stageLabel('mystery')).toBe('mystery')
  })

  it('shows each stat only to a viewer who may already see that data', () => {
    const snapshot = { ...EMPTY_SNAPSHOT, active: 12, starting: 1 }
    const input = { snapshot, away: [{ id: '1', name: 'Ana', type: 'annual', until: '2026-09-16', backOn: false }], summary: summaryOf([row('j1', 'screening')]), requestsToDecide: 3 }

    expect(statTiles({ ...input, viewer: viewerWith() }).map((t) => t.key)).toEqual([])
    expect(statTiles({ ...input, viewer: viewerWith('people.view') }).map((t) => t.key)).toEqual(['active'])
    expect(statTiles({ ...input, viewer: viewerWith('leave.approve') }).map((t) => t.key)).toEqual(['away'])
    expect(statTiles({ ...input, viewer: viewerWith('candidates.view') }).map((t) => t.key)).toEqual(['applicants'])
    expect(statTiles({ ...input, viewer: viewerWith('jobs.approve') }).map((t) => t.key)).toEqual(['requests'])
  })

  it('states the headline numbers and keeps the payroll tile on what the database returned', () => {
    const snapshot = { ...EMPTY_SNAPSHOT, active: 12, starting: 1, payroll: [PAYROLL] }
    const all = viewerWith('people.view', 'leave.view', 'candidates.view', 'jobs.approve')
    const tiles = statTiles({ snapshot, away: [], summary: summaryOf([row('j1', 'screening'), row('j1', 'hired', false)]), requestsToDecide: 3, viewer: all })
    expect(tiles.map((t) => [t.key, t.value])).toEqual([
      ['active', 12],
      ['away', 0],
      ['applicants', 1],
      ['requests', 3],
      ['payroll', '1,000 EUR'],
    ])
    expect(tiles[0]?.sub).toBe('1 starting soon')
    // No payroll row came back (no payroll.summary anywhere) → no tile, whatever the viewer claims.
    expect(statTiles({ snapshot: { ...snapshot, payroll: [] }, away: [], summary: EMPTY_HIRING_SUMMARY, requestsToDecide: 0, viewer: all }).map((t) => t.key)).not.toContain('payroll')
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

  it('reads the not responding count the database made', () => {
    expect(notRespondingCount(summaryOf([], { not_responding: 7 }))).toBe(7)
    expect(notRespondingCount(EMPTY_HIRING_SUMMARY)).toBe(0)
  })

  it('validates the hiring_summary JSON at the boundary', () => {
    const raw = { by_job: [row('j1', 'screening')], not_responding: 2, recent: [] }
    expect(parseHiringSummary(raw)).toEqual(raw)
    expect(() => parseHiringSummary({ by_job: [{ job_id: 'j1' }], not_responding: 0, recent: [] })).toThrow()
    expect(() => parseHiringSummary(null)).toThrow()
  })
})
