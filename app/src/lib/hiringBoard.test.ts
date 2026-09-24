import { describe, expect, it } from 'vitest'
import { BOARD_COLUMNS, daysSince, jobBoard, upcomingInterviews, whenLabel, type InterviewLite } from './hiringBoard'
import type { ApplicationLite, JobLite } from './dashboard'

const app = (job_id: string, stage_key: string, title = `Job ${job_id}`): ApplicationLite => ({
  id: `${job_id}-${stage_key}-${Math.random()}`,
  job_id,
  stage_key,
  received_at: '2026-09-01T10:00:00Z',
  candidate: { full_name: 'Cand' },
  job: { title, company: { name: 'Synami' } },
})

describe('daysSince', () => {
  it('counts whole calendar days from a timestamp or a date to today', () => {
    expect(daysSince('2026-09-20T23:59:00Z', '2026-09-24')).toBe(4)
    expect(daysSince('2026-09-24', '2026-09-24')).toBe(0)
  })
  it('never goes negative and says nothing without a date', () => {
    expect(daysSince('2026-09-30', '2026-09-24')).toBe(0)
    expect(daysSince(null, '2026-09-24')).toBeNull()
  })
})

describe('jobBoard', () => {
  it('puts every stage in its column, rejected and withdrawn together as closed', () => {
    expect(BOARD_COLUMNS.map((c) => c.key)).toEqual(['new', 'screening', 'interview', 'offer', 'hired', 'closed'])
    const [row] = jobBoard(
      [app('j1', 'new'), app('j1', 'new'), app('j1', 'interview'), app('j1', 'rejected'), app('j1', 'withdrawn')],
      [],
      '2026-09-24',
    )
    expect(row!.counts).toEqual({ new: 2, screening: 0, interview: 1, offer: 0, hired: 0, closed: 2 })
    expect(row!.total).toBe(5)
    expect(row!.inPlay).toBe(3)
  })

  it('marks the furthest stage anyone has reached, never the closed column', () => {
    const rows = jobBoard([app('a', 'screening'), app('a', 'offer'), app('b', 'rejected'), app('c', 'hired')], [], '2026-09-24')
    const furthest = Object.fromEntries(rows.map((r) => [r.jobId, r.furthest]))
    expect(furthest).toEqual({ a: 'offer', b: null, c: 'hired' })
  })

  it('orders by who is still in play, then title, and dates each row from its job', () => {
    const jobs: JobLite[] = [{ id: 'b', title: 'B', status: 'open', company: null, request: null, opened_at: '2026-09-14T08:00:00Z' }]
    const rows = jobBoard([app('a', 'new', 'Alpha'), app('b', 'new', 'Beta'), app('b', 'screening', 'Beta'), app('c', 'new', 'Charlie')], jobs, '2026-09-24')
    expect(rows.map((r) => r.title)).toEqual(['Beta', 'Alpha', 'Charlie'])
    expect(rows[0]!.daysOpen).toBe(10)
    expect(rows[1]!.daysOpen).toBeNull()
  })

  it('has no row for a job nobody applied to', () => {
    expect(jobBoard([], [{ id: 'x', title: 'X', status: 'open', company: null, request: null }], '2026-09-24')).toEqual([])
  })
})

const interview = (over: Partial<InterviewLite>): InterviewLite => ({
  id: 'i1',
  kind: 'technical',
  scheduled_at: '2026-09-25T09:30:00Z',
  application: { id: 'ap1', candidate: { full_name: 'Ana' }, job: { title: 'Vue developer', company: { name: 'Synami' } } },
  panel: [{ person: { full_name: 'Naum' } }, { person: null }],
  ...over,
})

describe('upcomingInterviews', () => {
  it('shapes each interview for a row, soonest first, with the panel it can see', () => {
    const rows = upcomingInterviews([
      interview({ id: 'later', scheduled_at: '2026-09-27T09:00:00Z' }),
      interview({ id: 'soon', kind: 'phone', panel: [] }),
    ])
    expect(rows.map((r) => r.id)).toEqual(['soon', 'later'])
    expect(rows[0]).toMatchObject({ applicationId: 'ap1', candidate: 'Ana', job: 'Vue developer', company: 'Synami', kind: 'Phone screen', panel: [] })
    expect(rows[1]!.panel).toEqual(['Naum'])
  })

  it('falls back when the candidate or the job is hidden', () => {
    const [row] = upcomingInterviews([interview({ application: null })])
    expect(row).toMatchObject({ applicationId: null, candidate: 'Candidate', job: '—', company: '—' })
  })
})

describe('whenLabel', () => {
  const now = new Date('2026-09-24T08:00:00')
  it('names today and tomorrow, then the weekday and date', () => {
    expect(whenLabel(new Date('2026-09-24T15:00:00').toISOString(), now)).toBe('Today · 15:00')
    expect(whenLabel(new Date('2026-09-25T09:05:00').toISOString(), now)).toBe('Tomorrow · 09:05')
    expect(whenLabel(new Date('2026-09-28T11:00:00').toISOString(), now)).toBe('Mon 28 Sep · 11:00')
  })
})
