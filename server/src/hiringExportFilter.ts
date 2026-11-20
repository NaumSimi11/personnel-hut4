import { z } from 'zod'
import type { ExportApplication, ExportCandidate } from './hiringExport.js'

/**
 * The Applicants list's filters, applied to the export (20 Nov): what HR sees
 * on the list is what lands in the file.
 *
 * The rules are the list's own (app/src/lib/applicationQueries.ts and
 * likePattern.ts), kept in step by hiringExportFilter.test.ts:
 *   * stage "live" (In progress) = still in play; "all" = no stage filter;
 *     a stage key = that stage
 *   * status = that status; company = that company
 *   * name = the candidate's name contains it, any case, % and _ literal
 * Every filter goes to the database; nothing is filtered afterwards.
 */

const STAGES = ['live', 'all', 'screening', 'interview', 'offer', 'hired'] as const
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export const exportFilterInput = z.object({
  stage: z.enum(STAGES).default('all'),
  status: z.string().regex(/^[a-z0-9_]*$/, 'Unknown status.').max(64).default(''),
  companyId: z.string().refine((v) => v === '' || UUID.test(v), 'Unknown company.').default(''),
  search: z.string().max(200).default(''),
})

export type ExportFilter = { stage: string; status: string; companyId: string; search: string }

export type ExportQueryPlan = {
  eq: [column: string, value: string | boolean][]
  nameLike: string | null
}

/** No filter at all: the whole list, as "Export everyone" gives it. */
export function isWholeList(f: ExportFilter): boolean {
  return f.stage === 'all' && !f.status && !f.companyId && !f.search.trim()
}

function stageEq(stage: string): [string, string | boolean][] {
  if (stage === 'live') return [['in_play', true]]
  if (stage === 'all') return []
  return [['stage_key', stage]]
}

export function exportQueryPlan(f: ExportFilter): ExportQueryPlan {
  const term = f.search.trim()
  return {
    eq: [
      ...stageEq(f.stage),
      ...(f.status ? [['sub_status_key', f.status] as [string, string]] : []),
      ...(f.companyId ? [['company_id', f.companyId] as [string, string]] : []),
    ],
    nameLike: term ? term : null,
  }
}

/** The list's name search: anywhere in the name, with the wildcards a name may hold taken literally. */
export function likePattern(term: string): string {
  return `%${term.trim().replace(/[\\%_]/g, (c) => `\\${c}`)}%`
}

// ------------------------------------------------------------- the reading

/** The slice of the PostgREST builder the export uses, so a test can stand in for it. */
type Builder = {
  select(columns: string): Builder
  eq(column: string, value: string | boolean): Builder
  ilike(column: string, pattern: string): Builder
  order(column: string): Builder
  range(from: number, to: number): PromiseLike<{ data: unknown[] | null; error: { message: string } | null }>
}
export type ExportDb = { from(table: string): unknown }

const PAGE = 1000
const MAX_PAGES = 20

type FilteredRow = ExportApplication & { id: string; candidate: ExportCandidate | null }

export type FilteredExport = { candidates: ExportCandidate[]; applications: ExportApplication[] }

/** The applications the filters match, each with its candidate, one page of 1,000 at a time. */
export async function readFilteredExport(db: ExportDb, f: ExportFilter): Promise<FilteredExport> {
  const plan = exportQueryPlan(f)
  const rows: FilteredRow[] = []
  for (let page = 0; page < MAX_PAGES; page += 1) {
    let query = (db.from('applications') as Builder).select(
      'id, candidate_id, job_id, stage_key, sub_status_key, candidate:candidates!inner(id, full_name, provider_ref, current_title)',
    )
    for (const [column, value] of plan.eq) query = query.eq(column, value)
    if (plan.nameLike) query = query.ilike('candidate.full_name', likePattern(plan.nameLike))
    const from = page * PAGE
    const { data, error } = await query.order('id').range(from, from + PAGE - 1)
    if (error) throw new Error(error.message)
    const chunk = (data ?? []) as FilteredRow[]
    rows.push(...chunk)
    if (chunk.length < PAGE) {
      const candidates = new Map<string, ExportCandidate>()
      for (const r of rows) if (r.candidate) candidates.set(r.candidate.id, r.candidate)
      return {
        candidates: [...candidates.values()],
        applications: rows.map((r) => ({ candidate_id: r.candidate_id, job_id: r.job_id, stage_key: r.stage_key, sub_status_key: r.sub_status_key })),
      }
    }
  }
  throw new Error(`More than ${PAGE * MAX_PAGES} rows; the export stops rather than hand over a partial file.`)
}

// ---------------------------------------------------------------- the request

export type ExportRequest =
  | { ok: true; today: string; scope: 'everyone' }
  | { ok: true; today: string; scope: 'filtered'; filter: ExportFilter }
  | { ok: false; error: string }

/**
 * What the route takes from the body: `scope: 'everyone'` (or no filter at
 * all) is the whole file, candidates on no job included; a filter exports
 * what the list shows. A filter the list cannot send is refused, never
 * quietly widened to everything.
 */
export function exportRequest(body: unknown): ExportRequest {
  const b = (body && typeof body === 'object' ? body : {}) as { today?: unknown; scope?: unknown; filter?: unknown }
  const today = typeof b.today === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(b.today) ? b.today : new Date().toISOString().slice(0, 10)
  if (b.scope === 'everyone' || b.filter === undefined) return { ok: true, today, scope: 'everyone' }
  const parsed = exportFilterInput.safeParse(b.filter)
  if (!parsed.success) return { ok: false, error: 'Those filters cannot be exported. Reload the page and try again.' }
  return { ok: true, today, scope: 'filtered', filter: parsed.data }
}
