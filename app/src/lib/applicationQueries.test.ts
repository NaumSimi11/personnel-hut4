import { describe, expect, it } from 'vitest'
import { applicantsQueryPlan, orderNewestFirst } from './applicationQueries'

/** Records the order calls a query builder receives. */
function recorder() {
  const calls: [string, { ascending?: boolean } | undefined][] = []
  const q = {
    order(column: string, options?: { ascending?: boolean }) {
      calls.push([column, options])
      return q
    },
  }
  return { q, calls }
}

describe('orderNewestFirst', () => {
  it('orders by received_at, newest first, then id (imported rows share created_at)', () => {
    const { q, calls } = recorder()
    orderNewestFirst(q)
    expect(calls).toEqual([
      ['received_at', { ascending: false }],
      ['id', { ascending: true }],
    ])
  })
})

describe('applicantsQueryPlan', () => {
  const base = { stage: 'live', status: '', companyId: '', search: '' }

  it('In progress: in play, any company', () => {
    expect(applicantsQueryPlan(base)).toEqual({ eq: [['in_play', true]], nameLike: null })
  })

  it('runs the company filter in the query', () => {
    expect(applicantsQueryPlan({ ...base, companyId: 'co-1' }).eq).toEqual([
      ['in_play', true],
      ['company_id', 'co-1'],
    ])
  })

  it('status, company and name all filter on top of the stage', () => {
    expect(applicantsQueryPlan({ stage: 'all', status: 'contacted', companyId: 'co-1', search: ' ana ' })).toEqual({
      eq: [
        ['sub_status_key', 'contacted'],
        ['company_id', 'co-1'],
      ],
      nameLike: 'ana',
    })
  })

  it('a stage filters by stage; All stages by nothing', () => {
    expect(applicantsQueryPlan({ ...base, stage: 'interview' }).eq).toEqual([['stage_key', 'interview']])
    expect(applicantsQueryPlan({ ...base, stage: 'all' }).eq).toEqual([])
  })
})
