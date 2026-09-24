import { describe, expect, it } from 'vitest'
import { activitySentence, averageDays, fillLine, offerRate, parseInsights } from './insights'

const RAW = {
  company_id: 'c1',
  from: '2026-06-01',
  to: '2026-09-24',
  can_see_candidates: true,
  fill: [
    { job_id: 'j1', title: 'Vue', status: 'open', opened_on: '2026-01-01', target_start_date: '2026-03-01', headcount: 2, applicants: 36, hires: 1, filled_on: null, days: 266, late_days: 207 },
    { job_id: 'j2', title: 'QA', status: 'filled', opened_on: '2026-08-01', target_start_date: null, headcount: 1, applicants: 9, hires: 1, filled_on: '2026-08-21', days: 20, late_days: 0 },
  ],
  hires: [
    { application_id: 'a1', candidate: 'Ana', job_id: 'j2', job: 'QA', received_on: '2026-08-05', hired_on: '2026-08-21', days: 16 },
    { application_id: 'a2', candidate: 'Bo', job_id: 'j2', job: 'QA', received_on: '2026-08-01', hired_on: '2026-08-21', days: 21 },
  ],
  offers: { extended: 1, accepted: 2, declined: 1 },
  activity: [
    { at: '2026-09-22T16:06:00Z', application_id: 'a3', candidate: 'Goran', job_id: 'j1', job: 'Vue', from_stage: 'new', to_stage: 'screening', actor: 'Ivana Frost' },
  ],
}

describe('insights', () => {
  it('parses the RPC and reads a missing section as empty', () => {
    const data = parseInsights(RAW)
    expect(data.fill).toHaveLength(2)
    const bare = parseInsights({ company_id: 'c1', from: 'x', to: 'y', can_see_candidates: false })
    expect(bare.fill).toEqual([])
    expect(bare.hires).toEqual([])
    expect(bare.activity).toEqual([])
    expect(bare.offers).toEqual({ extended: 0, accepted: 0, declined: 0 })
  })

  it('averages days to one decimal, dash when there is nothing to average', () => {
    const data = parseInsights(RAW)
    expect(averageDays(data.hires)).toBe('18.5')
    expect(averageDays([])).toBe('—')
  })

  it('rates offers by the answers given; one still out does not count', () => {
    expect(offerRate({ extended: 1, accepted: 2, declined: 1 })).toBe('67%')
    expect(offerRate({ extended: 3, accepted: 0, declined: 0 })).toBe('—')
  })

  it('says whether a job is still open or when it filled, and how far past target', () => {
    const [open, filled] = parseInsights(RAW).fill
    expect(fillLine(open!)).toBe('Open 266 days · 207 days past target start')
    expect(fillLine(filled!)).toBe('Filled in 20 days')
  })

  it('writes a stage change the way Zoho did, naming nobody it cannot see', () => {
    const [row] = parseInsights(RAW).activity
    expect(activitySentence(row!)).toBe('Goran moved from Applied to Screening for Vue by Ivana Frost')
    expect(activitySentence({ ...row!, from_stage: null, actor: null })).toBe('Goran moved to Screening for Vue')
  })
})
