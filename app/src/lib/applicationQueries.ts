import { NOT_RESPONDING_FILTER } from '@/lib/stageStatuses'

/**
 * How the application lists ask the database (spec 2026-11-05, egress): every
 * filter runs in the query and only one page comes back, so "Showing N of
 * total" counts what the filter matches, not what happened to be loaded.
 */

type Orderable<Q> = { order(column: string, options?: { ascending?: boolean }): Q }

/** Newest received first, then id: imported rows share created_at, so only this order is stable. */
export function orderNewestFirst<Q extends Orderable<Q>>(query: Q): Q {
  return query.order('received_at', { ascending: false }).order('id', { ascending: true })
}

export type ApplicantsFilter = { stage: string; status: string; companyId: string; search: string }

/**
 * The Applicants list's filters as query parts. `notResponding` means the
 * rows come from `not_responding_applications` (the database's rule, 0097)
 * instead of the table; the equality filters and the name search apply on
 * top either way.
 */
export type ApplicantsQueryPlan = {
  notResponding: boolean
  eq: [column: string, value: string | boolean][]
  nameLike: string | null
}

function stageEq(stage: string): [string, string | boolean][] {
  if (stage === 'live') return [['in_play', true]]
  if (stage === 'all' || stage === NOT_RESPONDING_FILTER) return []
  return [['stage_key', stage]]
}

export function applicantsQueryPlan(filter: ApplicantsFilter): ApplicantsQueryPlan {
  const term = filter.search.trim()
  return {
    notResponding: filter.stage === NOT_RESPONDING_FILTER,
    eq: [
      ...stageEq(filter.stage),
      ...(filter.status ? [['sub_status_key', filter.status] as [string, string]] : []),
      ...(filter.companyId ? [['company_id', filter.companyId] as [string, string]] : []),
    ],
    nameLike: term ? term : null,
  }
}

