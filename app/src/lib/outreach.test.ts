import { describe, expect, it } from 'vitest'
import {
  NOT_RESPONDING_DAYS,
  OUTREACH_BLOCKED,
  SUB_STATUS_STAGES,
  notResponding,
  outreachBadge,
  outreachLine,
  subStatusesFor,
  type OutreachRow,
  type SubStatusRow,
} from './outreach'

const TODAY = '2026-09-21'

function row(over: Partial<OutreachRow>): OutreachRow {
  return {
    stage_key: 'screening',
    sub_status_key: 'contacted',
    last_activity_at: null,
    received_at: '2026-06-01T09:00:00+00:00',
    job_status: 'open',
    ...over,
  }
}

function isoDaysAgo(today: string, days: number): string {
  const d = new Date(`${today}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() - days)
  return `${d.toISOString().slice(0, 10)}T09:00:00+00:00`
}

describe('notResponding', () => {
  it('is true past 30 days on a live job at an open sub-status', () => {
    const r = row({ last_activity_at: isoDaysAgo(TODAY, 31) })
    expect(notResponding(r, TODAY)).toBe(true)
  })

  it('is false with an activity today', () => {
    const r = row({ last_activity_at: isoDaysAgo(TODAY, 0) })
    expect(notResponding(r, TODAY)).toBe(false)
  })

  it('is false right at the 30-day boundary (not yet older than 30 days)', () => {
    const r = row({ last_activity_at: isoDaysAgo(TODAY, NOT_RESPONDING_DAYS) })
    expect(notResponding(r, TODAY)).toBe(false)
  })

  it('falls back to received_at when there is no event yet', () => {
    const r = row({ last_activity_at: null, received_at: isoDaysAgo(TODAY, 45) })
    expect(notResponding(r, TODAY)).toBe(true)
  })

  it('is false for a terminal stage even if stale', () => {
    for (const stage_key of ['hired', 'rejected', 'withdrawn']) {
      const r = row({ stage_key, last_activity_at: isoDaysAgo(TODAY, 60) })
      expect(notResponding(r, TODAY), stage_key).toBe(false)
    }
  })

  it('is false off a live job', () => {
    for (const job_status of ['filled', 'closed']) {
      const r = row({ job_status, last_activity_at: isoDaysAgo(TODAY, 60) })
      expect(notResponding(r, TODAY), job_status).toBe(false)
    }
    for (const job_status of ['ready', 'open', 'on_hold']) {
      const r = row({ job_status, last_activity_at: isoDaysAgo(TODAY, 60) })
      expect(notResponding(r, TODAY), job_status).toBe(true)
    }
  })

  it('is false for a sub-status that is not one of sourced/contact_attempted/contacted', () => {
    for (const sub_status_key of ['applied', 'interested', 'awaiting_evaluation', 'qualified', null]) {
      const r = row({ sub_status_key, last_activity_at: isoDaysAgo(TODAY, 60) })
      expect(notResponding(r, TODAY), String(sub_status_key)).toBe(false)
    }
    for (const sub_status_key of ['sourced', 'contact_attempted', 'contacted']) {
      const r = row({ sub_status_key, last_activity_at: isoDaysAgo(TODAY, 60) })
      expect(notResponding(r, TODAY), sub_status_key).toBe(true)
    }
  })
})

describe('outreachBadge', () => {
  it('renders the badge when not responding, empty otherwise', () => {
    expect(outreachBadge(row({ last_activity_at: isoDaysAgo(TODAY, 31) }), TODAY)).toBe('Not responding')
    expect(outreachBadge(row({ last_activity_at: isoDaysAgo(TODAY, 1) }), TODAY)).toBe('')
  })
})

describe('subStatusesFor', () => {
  const all: SubStatusRow[] = [
    { key: 'applied', stage_key: 'new', label: 'Applied', sort_order: 10, archived_at: null },
    { key: 'sourced', stage_key: 'new', label: 'Sourced — not yet contacted', sort_order: 20, archived_at: null },
    { key: 'contact_attempted', stage_key: 'new', label: 'Contact attempted — no answer yet', sort_order: 30, archived_at: null },
    { key: 'retired_new', stage_key: 'new', label: 'Retired', sort_order: 5, archived_at: '2026-01-01T00:00:00+00:00' },
    { key: 'contacted', stage_key: 'screening', label: 'In conversation', sort_order: 10, archived_at: null },
    { key: 'interested', stage_key: 'screening', label: 'Interested', sort_order: 20, archived_at: null },
    { key: 'awaiting_evaluation', stage_key: 'screening', label: 'Awaiting evaluation', sort_order: 30, archived_at: null },
    { key: 'qualified', stage_key: 'screening', label: 'Qualified — ready for interview', sort_order: 40, archived_at: null },
  ]

  it('returns the unarchived sub-statuses of one stage, sorted, without archived_at', () => {
    expect(subStatusesFor(all, 'new')).toEqual([
      { key: 'applied', stage_key: 'new', label: 'Applied', sort_order: 10 },
      { key: 'sourced', stage_key: 'new', label: 'Sourced — not yet contacted', sort_order: 20 },
      { key: 'contact_attempted', stage_key: 'new', label: 'Contact attempted — no answer yet', sort_order: 30 },
    ])
    expect(subStatusesFor(all, 'screening')).toHaveLength(4)
  })

  it('is empty for a stage with no sub-statuses', () => {
    expect(subStatusesFor(all, 'interview')).toEqual([])
  })
})

describe('outreachLine', () => {
  const labels = { sourced: 'Sourced — not yet contacted', contact_attempted: 'Contact attempted — no answer yet' }

  it('names both sides and appends the note', () => {
    expect(outreachLine({ from_sub_status_key: 'sourced', to_sub_status_key: 'contact_attempted', body: 'Left a voicemail.' }, labels)).toBe(
      'Outreach: Sourced — not yet contacted → Contact attempted — no answer yet · Left a voicemail.',
    )
  })

  it('omits the note when the body is empty', () => {
    expect(outreachLine({ from_sub_status_key: 'sourced', to_sub_status_key: 'contact_attempted', body: null }, labels)).toBe(
      'Outreach: Sourced — not yet contacted → Contact attempted — no answer yet',
    )
    expect(outreachLine({ from_sub_status_key: 'sourced', to_sub_status_key: 'contact_attempted', body: '' }, labels)).toBe(
      'Outreach: Sourced — not yet contacted → Contact attempted — no answer yet',
    )
  })

  it('shows — for a missing from (first outreach on this application)', () => {
    expect(outreachLine({ from_sub_status_key: null, to_sub_status_key: 'sourced', body: null }, labels)).toBe('Outreach: — → Sourced — not yet contacted')
  })

  it('falls back to the raw key when a label is missing', () => {
    expect(outreachLine({ from_sub_status_key: 'sourced', to_sub_status_key: 'qualified', body: null }, labels)).toBe(
      'Outreach: Sourced — not yet contacted → qualified',
    )
  })
})

describe('constants', () => {
  it('carry the plan values verbatim', () => {
    expect(SUB_STATUS_STAGES).toEqual(['new', 'screening'])
    expect(NOT_RESPONDING_DAYS).toBe(30)
    expect(OUTREACH_BLOCKED).toBe('Outreach is logged at New or Screening.')
  })
})
