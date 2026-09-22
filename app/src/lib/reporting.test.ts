import { describe, expect, it } from 'vitest'
import { STAGE_ORDER, conversion, defaultRange, funnelCsv, parseReport, type RecruitmentReport } from './reporting'

const raw = {
  company_id: 'c1',
  from: '2026-06-01',
  to: '2026-09-01',
  kpis: { open_roles: 2, active_candidates: 5, received: 12, hires: 2, median_days_to_hire: 18.5, avg_days_to_hire: 20 },
  funnel: [
    {
      job_id: 'j1',
      title: 'Coordinator',
      status: 'open',
      received: 8,
      stages: { new: 2, screening: 1, interview: 2, offer: 0, hired: 1, rejected: 2, withdrawn: 0 },
      hired: 1,
    },
  ],
  sources: [
    { source: 'Company careers page', received: 9, interviewed: 4, hired: 2 },
    { source: 'Added by hand', received: 3, interviewed: 1, hired: 0 },
  ],
  attention: { overdue_next_actions: 1, unassigned: 3, stale: 2 },
}

describe('parseReport', () => {
  it('accepts the RPC shape and fills absent numbers with zero', () => {
    const report = parseReport(raw)
    expect(report.kpis.hires).toBe(2)
    expect(report.funnel[0]?.stages.offer).toBe(0)
    const sparse = parseReport({ ...raw, kpis: { ...raw.kpis, median_days_to_hire: null }, sources: [] })
    expect(sparse.kpis.median_days_to_hire).toBeNull()
    expect(sparse.sources).toEqual([])
  })

  it('reads the not-responding count, zero when a report predates it', () => {
    expect(parseReport(raw).attention.not_responding).toBe(0)
    const later = parseReport({ ...raw, attention: { ...raw.attention, not_responding: 4 } })
    expect(later.attention.not_responding).toBe(4)
  })

  it('rejects something that is not a report', () => {
    expect(() => parseReport({ nope: true })).toThrow()
  })
})

describe('conversion', () => {
  it('is a whole-number percentage, or a dash with no denominator', () => {
    expect(conversion(2, 8)).toBe('25%')
    expect(conversion(1, 3)).toBe('33%')
    expect(conversion(0, 0)).toBe('—')
  })
})

describe('defaultRange', () => {
  it('is the last 90 days ending today', () => {
    const { from, to } = defaultRange(new Date('2026-09-11T12:00:00Z'))
    expect(to).toBe('2026-09-11')
    expect(from).toBe('2026-06-13')
  })
})

describe('funnelCsv', () => {
  it('writes one row per job with the stages in pipeline order and quotes commas', () => {
    const report: RecruitmentReport = parseReport({
      ...raw,
      funnel: [{ ...raw.funnel[0], title: 'Ops, Coordinator' }],
    })
    const csv = funnelCsv(report)
    const lines = csv.split('\n')
    expect(lines[0]).toBe(`Job,Status,Received,${STAGE_ORDER.map((s) => s[0]!.toUpperCase() + s.slice(1)).join(',')}`)
    expect(lines[1]).toBe('"Ops, Coordinator",open,8,2,1,2,0,1,2,0')
  })
})

describe('funnelCsv formula safety', () => {
  it('neutralises cells that a spreadsheet would treat as formulas', () => {
    const report = parseReport({
      ...raw,
      funnel: [{ ...raw.funnel[0], title: '=HYPERLINK("http://evil.example")' }],
    })
    const row = funnelCsv(report).split('\n')[1] ?? ''
    expect(row.startsWith(`"'=HYPERLINK`)).toBe(true)
  })
})
