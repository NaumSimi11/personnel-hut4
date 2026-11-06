import { describe, expect, it } from 'vitest'
import { BOARD_COLUMNS, daysSince, jobBoard, upcomingInterviews, whenLabel, type InterviewLite } from './hiringBoard'
import type { HiringSummary, JobLite } from './dashboard'

const row = (job_id: string, stage_key: string, in_play = stage_key !== 'hired', count = 1) => ({ job_id, stage_key, in_play, count, last_received_at: '2026-09-01T10:00:00Z' })
const summaryOf = (by_job: HiringSummary['by_job']): HiringSummary => ({ by_job, not_responding: 0, recent: [] })
const job = (id: string, title: string, over: Partial<JobLite> = {}): JobLite => ({ id, title, status: 'open', company: { name: 'Synami' }, request: null, ...over })

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
  it('puts every stage in its column, anything out of play but a hire together as closed', () => {
    expect(BOARD_COLUMNS.map((c) => c.key)).toEqual(['screening', 'interview', 'offer', 'hired', 'closed'])
    expect(BOARD_COLUMNS.find((c) => c.key === 'offer')!.label).toBe('Offered')
    const [board] = jobBoard(
      summaryOf([row('j1', 'screening', true, 2), row('j1', 'interview'), row('j1', 'screening', false), row('j1', 'interview', false), row('j1', 'hired')]),
      [job('j1', 'Job j1')],
      '2026-09-24',
    )
    expect(board!.counts).toEqual({ screening: 2, interview: 1, offer: 0, hired: 1, closed: 2 })
    expect(board!.total).toBe(6)
    expect(board!.inPlay).toBe(3)
  })

  it('marks the furthest stage anyone has reached, never the closed column', () => {
    const rows = jobBoard(summaryOf([row('a', 'screening'), row('a', 'offer'), row('b', 'interview', false), row('c', 'hired')]), [job('a', 'A'), job('b', 'B'), job('c', 'C')], '2026-09-24')
    const furthest = Object.fromEntries(rows.map((r) => [r.jobId, r.furthest]))
    expect(furthest).toEqual({ a: 'offer', b: null, c: 'hired' })
  })

  it('orders by who is still in play, then title, and dates each row from its job', () => {
    const jobs = [job('a', 'Alpha'), job('b', 'Beta', { opened_at: '2026-09-14T08:00:00Z' }), job('c', 'Charlie')]
    const rows = jobBoard(summaryOf([row('a', 'screening'), row('b', 'screening'), row('b', 'interview'), row('c', 'screening')]), jobs, '2026-09-24')
    expect(rows.map((r) => r.title)).toEqual(['Beta', 'Alpha', 'Charlie'])
    expect(rows[0]!.daysOpen).toBe(10)
    expect(rows[1]!.daysOpen).toBeNull()
  })

  it('has no row for a job nobody applied to, and none for a job the viewer cannot read', () => {
    expect(jobBoard(summaryOf([]), [job('x', 'X')], '2026-09-24')).toEqual([])
    expect(jobBoard(summaryOf([row('ghost', 'screening')]), [], '2026-09-24')).toEqual([])
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
