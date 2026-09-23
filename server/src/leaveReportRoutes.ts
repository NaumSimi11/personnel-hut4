import type { FastifyInstance } from 'fastify'
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { env } from './env.js'
import { identityFromToken } from './supabaseAdmin.js'
import { buildLeaveReport } from './leaveReport.js'
import {
  balanceKey,
  describeRecordFilter,
  isRecordFilterActive,
  leaveReportFilename,
  matchesRecordFilter,
  reportYear,
  type RecordFilter,
  type ReportPerson,
  type ReportRequest,
} from '../../shared/leaveReport.js'

/**
 * POST /api/reports/leave-finance — the leave desk's "Download report",
 * the same workbook Field Notebook's manager desk hands out.
 *
 * Everything is read AS THE CALLER, so the report contains exactly the leave
 * they may already see: their own, plus every company where they hold
 * `leave.view` or `leave.approve` (0027's policy). That is a better gate than
 * Field Notebook's admin-only rule and needs no check of its own — a plain
 * employee pressing this gets a workbook of their own leave, which is true
 * and harmless.
 *
 * The filter arrives from the screen and is applied with the screen's own
 * predicate (`shared/leaveReport.ts`), so the file and the list on screen can
 * never disagree.
 */

/** PostgREST answers at most 1,000 rows; the holding's leave history is larger. */
const PAGE = 1000
const MAX_PAGES = 12

type RequestRow = {
  id: string
  person_id: string
  legacy_id: number | null
  start_date: string
  end_date: string
  working_days: number
  status: string
  deducts_balance: boolean
  leave_type: { label: string } | null
  person: { full_name: string } | null
  company: { id: string; name: string; country_code: string | null } | null
}

type EmploymentRow = {
  id: string
  person_id: string
  company_id: string
  status: string
  person: { full_name: string } | null
  company: { id: string; name: string; country_code: string | null } | null
}

/**
 * The client is untyped here, so an embedded row arrives as `any[]` whatever
 * the select says; the caller casts once, at the edge, to the shape it asked
 * for.
 */
type PageResult = { data: unknown[] | null; error: { message: string } | null }

async function pageAll<T>(query: (from: number, to: number) => PromiseLike<PageResult>): Promise<T[]> {
  const rows: T[] = []
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const from = page * PAGE
    const { data, error } = await query(from, from + PAGE - 1)
    if (error) throw new Error(error.message)
    const chunk = (data ?? []) as T[]
    rows.push(...chunk)
    if (chunk.length < PAGE) break
  }
  return rows
}

/**
 * The approved leave the caller may see, shaped for the report.
 *
 * Approved only — one question, "who was actually away", the same one Field
 * Notebook's export answers. Pending and rejected rows are decisions nobody
 * has taken yet or has already refused, and a cancelled one did not happen.
 */
async function readRequests(db: SupabaseClient): Promise<ReportRequest[]> {
  const rows = await pageAll<RequestRow>((from, to) =>
    db
      .from('leave_requests')
      .select(
        `id, person_id, legacy_id, start_date, end_date, working_days, status, deducts_balance,
         leave_type:leave_types(label), person:people!leave_requests_person_id_fkey(full_name),
         company:companies(id, name, country_code)`,
      )
      .eq('status', 'approved')
      .order('id')
      .range(from, to),
  )
  return rows.map((r) => ({
    // Field Notebook's number where the row came from it; ours otherwise.
    // Finance reconciles against the number they were given at the time.
    reference: r.legacy_id != null ? String(r.legacy_id) : r.id,
    person_id: r.person_id,
    // Empty, not a dash: the filter reads these, and nobody searches for "—".
    // The sheet puts the dash in when it writes the row.
    person_name: r.person?.full_name ?? '',
    company_id: r.company?.id ?? '',
    company_name: r.company?.name ?? '',
    country_code: r.company?.country_code ?? null,
    leave_type: r.leave_type?.label ?? '',
    start_date: r.start_date,
    end_date: r.end_date,
    working_days: r.working_days,
    status: r.status,
    deducts_balance: r.deducts_balance,
  }))
}

/**
 * One summary row per person and company, with the balance read through the
 * same `leave_balance` the Balances screen uses — so the two always agree,
 * including its rule that an expired carry-over is worth nothing.
 */
/** A balance is per person, per company, per year — so one row per pair. */
const REPORTED_STATUSES = new Set(['active', 'former'])
/** How many balance lookups run at once. The holding is 42 people; a fan-out
 *  of thousands from one function invocation is how a report takes a service
 *  down with it. */
const BALANCE_CONCURRENCY = 8

async function readPeople(
  db: SupabaseClient,
  year: number,
  only: ReadonlySet<string> | null,
): Promise<ReportPerson[]> {
  const rows = await pageAll<EmploymentRow>((from, to) =>
    db
      .from('employment_periods')
      .select('id, person_id, company_id, status, person:people!employment_periods_person_id_fkey(full_name), company:companies(id, name, country_code)')
      // By the primary key: `person_id` is not unique, and a page boundary on
      // a non-unique order silently drops or repeats rows.
      .order('id')
      .range(from, to),
  )

  // One row per person and company. A rehire is two employment periods and
  // one balance, so exporting both would have finance counting the days
  // twice; a draft period is not an employment yet and says nothing.
  const wanted = new Map<string, EmploymentRow>()
  for (const r of rows) {
    if (!REPORTED_STATUSES.has(r.status)) continue
    const key = balanceKey(r.person_id, r.company_id)
    if (only && !only.has(key)) continue
    // Active beats former: somebody rehired is currently employed.
    const held = wanted.get(key)
    if (!held || (held.status !== 'active' && r.status === 'active')) wanted.set(key, r)
  }

  const queue = [...wanted.values()]
  const people: ReportPerson[] = []
  for (let i = 0; i < queue.length; i += BALANCE_CONCURRENCY) {
    const batch = await Promise.all(
      queue.slice(i, i + BALANCE_CONCURRENCY).map(async (r): Promise<ReportPerson> => {
        const { data } = await db.rpc('leave_balance', {
          p_person_id: r.person_id,
          p_company_id: r.company_id,
          p_year: year,
        })
        const b = (data ?? {}) as Record<string, unknown>
        const num = (key: string): number => Number(b[key] ?? 0)
        return {
          person_name: r.person?.full_name ?? '',
          company_name: r.company?.name ?? '',
          country_code: r.company?.country_code ?? null,
          employment_status: r.status,
          entitlement: num('entitlement'),
          // What the person has actually taken against the balance: the days
          // charged to this year's entitlement plus those charged to the
          // carry-over, which is the one number finance calls "used".
          approved_days: num('used') + num('carry_over_used'),
          remaining: num('remaining'),
          carry_over_remaining: num('carry_over_remaining'),
          has_balance: b.exists === true,
        }
      }),
    )
    people.push(...batch)
  }
  return people
}

export function registerLeaveReportRoutes(app: FastifyInstance): void {
  app.post('/api/reports/leave-finance', async (req, reply) => {
    const token = (req.headers.authorization ?? '').replace(/^Bearer /, '')
    if (!token) return reply.code(401).send({ error: 'Sign in to continue.' })
    const who = await identityFromToken(token)
    if (!who) return reply.code(401).send({ error: 'Sign in to continue.' })

    const body = (req.body ?? {}) as Partial<RecordFilter> & { companyName?: string; today?: string }
    const filter: RecordFilter = {
      // A month that is not a month is no filter at all, rather than a NaN
      // year in the balance lookup.
      month: typeof body.month === 'string' && /^\d{4}-\d{2}$/.test(body.month) ? body.month : 'all',
      company: typeof body.company === 'string' ? body.company.slice(0, 120) : 'all',
      query: typeof body.query === 'string' ? body.query.slice(0, 120) : '',
    }
    const today = /^\d{4}-\d{2}-\d{2}$/.test(body.today ?? '') ? (body.today as string) : new Date().toISOString().slice(0, 10)

    const url = env('SUPABASE_URL') ?? ''
    const anon = env('SUPABASE_PUBLISHABLE_KEY') ?? env('VITE_SUPABASE_PUBLISHABLE_KEY') ?? ''
    const asCaller = createClient(url, anon, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    })

    try {
      const all = await readRequests(asCaller)
      const requests = all.filter((r) => matchesRecordFilter(r, filter))
      // The summary carries the people visible in that view. A balance has no
      // month, so it stays year-to-date — but only for those people. Only when
      // a filter is ACTUALLY applied: unfiltered, finance wants the whole
      // roster, and somebody who has taken no leave at all still has a balance
      // worth reporting. Narrowing on an untouched filter would drop exactly
      // the people whose entitlement is untouched.
      // Keyed by person AND company: a name cannot key a summary — two people
      // may share one, and one person may be employed in two companies, so a
      // company-filtered export would otherwise drag in their other company.
      const named = isRecordFilterActive(filter)
        ? new Set(requests.map((r) => balanceKey(r.person_id, r.company_id)))
        : null
      const people = await readPeople(asCaller, reportYear(filter, today), named)
      const workbook = buildLeaveReport({ requests, people })
      return reply.send({
        filename: leaveReportFilename(today, describeRecordFilter(filter, body.companyName ?? '')),
        base64: workbook.toString('base64'),
      })
    } catch (err) {
      req.log.error({ err }, 'leave finance report failed')
      return reply.code(500).send({ error: 'The report could not be built.' })
    }
  })
}
