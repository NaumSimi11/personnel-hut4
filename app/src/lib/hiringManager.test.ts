import { describe, expect, it } from 'vitest'
import { hmPanel, hmStatuses } from './hiringManager'
import type { SubStatusRow } from './hiringLabels'

const row = (key: string, sort: number, outcome: SubStatusRow['outcome'], hm = false, archived: string | null = null): SubStatusRow =>
  ({ key, label: key, stage_key: 'screening', sort_order: sort, outcome, archived_at: archived, hm_only: hm }) as SubStatusRow

const rows = [
  row('sourced', 10, 'open'),
  row('contact', 15, 'open', true),
  row('contacted', 20, 'open'),
  row('unqualified', 60, 'rejected'),
  row('contact_in_future', 70, 'withdrew', true),
  row('do_not_contact', 80, 'withdrew', true),
  row('old_hm', 90, 'open', true, '2026-01-01'),
]
const at = (stage_key: string, sub_status_key: string | null, extra: Partial<{ closed_at: string; job_status: string }> = {}) => ({
  stage_key,
  sub_status_key,
  closed_at: extra.closed_at ?? null,
  job_status: extra.job_status ?? 'open',
})

describe('hiring manager panel', () => {
  it('lists the live HM statuses in order', () => {
    expect(hmStatuses(rows).map((r) => r.key)).toEqual(['contact', 'contact_in_future', 'do_not_contact'])
  })

  it('is hidden for anyone but the job\'s hiring manager', () => {
    expect(hmPanel(at('screening', 'sourced'), rows, false)).toEqual({ mode: 'hidden' })
  })

  it('offers the three calls at Screening and marks the current one', () => {
    const panel = hmPanel(at('screening', 'do_not_contact'), rows, true)
    expect(panel.mode).toBe('decide')
    if (panel.mode !== 'decide') return
    expect(panel.choices.map((c) => [c.key, c.current])).toEqual([
      ['contact', false],
      ['contact_in_future', false],
      ['do_not_contact', true],
    ])
  })

  it('locks at Offer and past screening, saying why', () => {
    expect(hmPanel(at('offer', 'offer_made'), rows, true)).toMatchObject({ mode: 'locked', reason: expect.stringContaining('At Offer') })
    expect(hmPanel(at('interview', 'interview_hr'), rows, true)).toMatchObject({ mode: 'locked', reason: expect.stringContaining('Past screening') })
  })

  it('locks on a closed job, and on an HR outcome at screening', () => {
    expect(hmPanel(at('screening', 'sourced', { job_status: 'filled' }), rows, true)).toMatchObject({ mode: 'locked' })
    expect(hmPanel(at('screening', 'sourced', { closed_at: '2026-11-01T00:00:00Z' }), rows, true)).toMatchObject({ mode: 'locked' })
    expect(hmPanel(at('screening', 'unqualified'), rows, true)).toMatchObject({ mode: 'locked', reason: expect.stringContaining('unqualified') })
  })
})
