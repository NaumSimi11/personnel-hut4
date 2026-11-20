import type { FastifyInstance } from 'fastify'
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { env } from './env.js'
import { identityFromToken } from './supabaseAdmin.js'
import {
  buildHiringExport,
  hiringExportFilename,
  type ExportApplication,
  type ExportCandidate,
  type ExportJob,
} from './hiringExport.js'
import { exportRequest, readFilteredExport } from './hiringExportFilter.js'

/**
 * POST /api/reports/hiring-export — the Applicants list as an .xlsx, one row
 * per application (see hiringExport.ts for the shape). With `filter` it holds
 * what the list's filters show (hiringExportFilter.ts); with
 * `scope: 'everyone'` every candidate, those on no job included.
 *
 * Read AS THE CALLER, so the file holds exactly the candidates and
 * applications row-level security already lets them see; no gate of its own.
 *
 * Egress (Free plan, 5 GB/month): only the columns the sheet needs are
 * selected, and the jobs are read once and joined here rather than embedded
 * in every application — about 1 MB in, a few hundred kB out, per export.
 */

/** PostgREST answers at most 1,000 rows a request. */
const PAGE = 1000
/** 20,000 rows: several times today's 4,155 applications, and a stop if something runs away. */
const MAX_PAGES = 20

type PageResult = { data: unknown[] | null; error: { message: string } | null }

async function pageAll<T>(query: (from: number, to: number) => PromiseLike<PageResult>): Promise<T[]> {
  const pages: T[][] = []
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const from = page * PAGE
    const { data, error } = await query(from, from + PAGE - 1)
    if (error) throw new Error(error.message)
    const chunk = (data ?? []) as T[]
    pages.push(chunk)
    if (chunk.length < PAGE) return pages.flat()
  }
  throw new Error(`More than ${PAGE * MAX_PAGES} rows; the export stops rather than hand over a partial file.`)
}

type JobRow = {
  id: string
  title: string
  zoho_id: string | null
  zoho_department: string | null
  company: { name: string } | null
  request: { department: { name: string } | null } | null
}

async function readJobs(db: SupabaseClient): Promise<ExportJob[]> {
  const rows = await pageAll<JobRow>((from, to) =>
    db
      .from('jobs')
      .select(
        `id, title, zoho_id:custom->zoho->>display_id, zoho_department:custom->zoho->>department,
         company:companies!jobs_company_id_fkey(name),
         request:hiring_requests!jobs_hiring_request_id_fkey(department:departments!hiring_requests_department_id_fkey(name))`,
      )
      .order('id')
      .range(from, to),
  )
  return rows.map((j) => ({
    id: j.id,
    title: j.title,
    zoho_id: j.zoho_id,
    // The hiring request's department is ours and current; Zoho's is what HR typed back then.
    department: j.request?.department?.name ?? j.zoho_department ?? null,
    company: j.company?.name ?? null,
  }))
}

async function readCandidates(db: SupabaseClient): Promise<ExportCandidate[]> {
  return pageAll<ExportCandidate>((from, to) =>
    db.from('candidates').select('id, full_name, provider_ref, current_title').order('id').range(from, to),
  )
}

async function readApplications(db: SupabaseClient): Promise<ExportApplication[]> {
  return pageAll<ExportApplication>((from, to) =>
    db.from('applications').select('candidate_id, job_id, stage_key, sub_status_key').order('id').range(from, to),
  )
}

async function readStatusLabels(db: SupabaseClient): Promise<Record<string, string>> {
  const rows = await pageAll<{ key: string; label: string }>((from, to) =>
    db.from('application_sub_statuses').select('key, label').order('key').range(from, to),
  )
  return Object.fromEntries(rows.map((r) => [r.key, r.label]))
}

export function registerHiringExportRoutes(app: FastifyInstance): void {
  app.post('/api/reports/hiring-export', async (req, reply) => {
    const token = (req.headers.authorization ?? '').replace(/^Bearer /, '')
    if (!token) return reply.code(401).send({ error: 'Sign in to continue.' })
    const who = await identityFromToken(token)
    if (!who) return reply.code(401).send({ error: 'Sign in to continue.' })

    const request = exportRequest(req.body)
    if (!request.ok) return reply.code(400).send({ error: request.error })

    const url = env('SUPABASE_URL') ?? ''
    const anon = env('SUPABASE_PUBLISHABLE_KEY') ?? env('VITE_SUPABASE_PUBLISHABLE_KEY') ?? ''
    const asCaller = createClient(url, anon, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    })

    try {
      const [rows, jobs, statusLabels] = await Promise.all([
        request.scope === 'filtered'
          ? readFilteredExport(asCaller, request.filter)
          : Promise.all([readCandidates(asCaller), readApplications(asCaller)]).then(([candidates, applications]) => ({ candidates, applications })),
        readJobs(asCaller),
        readStatusLabels(asCaller),
      ])
      const workbook = buildHiringExport({ ...rows, jobs, statusLabels })
      return reply.send({
        filename: hiringExportFilename(request.today, request.scope === 'filtered'),
        base64: workbook.toString('base64'),
        rows: rows.applications.length,
      })
    } catch (err) {
      req.log.error({ err }, 'hiring export failed')
      return reply.code(500).send({ error: 'The export could not be built.' })
    }
  })
}
