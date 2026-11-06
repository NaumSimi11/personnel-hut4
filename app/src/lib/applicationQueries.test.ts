import { describe, expect, it } from 'vitest'
import { applicantsQueryPlan, orderNewestFirst } from './applicationQueries'
import { NOT_RESPONDING_FILTER } from './stageStatuses'

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
    expect(applicantsQueryPlan(base)).toEqual({ notResponding: false, eq: [['in_play', true]], nameLike: null })
  })

  it('runs the company filter in the query', () => {
    expect(applicantsQueryPlan({ ...base, companyId: 'co-1' }).eq).toEqual([
      ['in_play', true],
      ['company_id', 'co-1'],
    ])
  })

  it('Not responding goes to the database rule, still with company, status and name', () => {
    expect(applicantsQueryPlan({ stage: NOT_RESPONDING_FILTER, status: 'contacted', companyId: 'co-1', search: ' ana ' })).toEqual({
      notResponding: true,
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
