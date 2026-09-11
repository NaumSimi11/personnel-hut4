import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import multipart from '@fastify/multipart'
import { randomUUID } from 'node:crypto'
import {
  CV_MAX_BYTES,
  RateLimiter,
  applicationInput,
  checkAnswers,
  cvExtension,
  isDuplicateApplication,
  isHoneypotTripped,
  isShortCode,
  publicBrief,
  publicCompany,
  referenceFor,
  serialised,
  summaryOf,
  validateCv,
} from './careers.js'
import { env, requiredEnv } from './env.js'
import { serviceDb } from './supabaseAdmin.js'

/**
 * The public careers surface (plan 019). These are the only endpoints an
 * anonymous visitor can reach: a company's open roles, one role's public
 * brief, and the application form. They run with the service role, so what
 * they expose is decided here — never by RLS — and kept to the public brief.
 *
 * Abuse controls: a honeypot field (bots fill it, browsers don't — such
 * submissions are dropped silently with a success-looking response), and
 * in-memory sliding-window rate limits per IP and per email address.
 */

// Per hour. Overridable for deployments behind a shared office NAT or for CI.
const HOUR = 60 * 60 * 1000
const ipLimiter = new RateLimiter({ max: Number(env('CAREERS_RATE_IP_PER_HOUR') ?? 30), windowMs: HOUR })
const emailLimiter = new RateLimiter({ max: Number(env('CAREERS_RATE_EMAIL_PER_HOUR') ?? 3), windowMs: HOUR })

function fail(reply: FastifyReply, status: number, message: string) {
  return reply.status(status).send({ error: message })
}

type CompanyRow = { id: string; name: string; short_code: string; website: string | null; brand: unknown }

async function findCompany(code: string): Promise<CompanyRow | null> {
  if (!isShortCode(code)) return null
  const { data } = await serviceDb()
    .from('companies')
    .select('id, name, short_code, website, brand')
    .eq('short_code', code.toUpperCase())
    .eq('kind', 'company')
    .is('archived_at', null)
    .maybeSingle()
  return (data as CompanyRow | null) ?? null
}

type JobRow = { id: string; title: string; description: string | null; screening_questions: unknown }

/** A role is public only while it is open with a live careers listing. */
async function listedJobs(companyId: string): Promise<JobRow[]> {
  const { data } = await serviceDb()
    .from('jobs')
    .select('id, title, description, screening_questions, job_channels!inner(channel_key, status)')
    .eq('company_id', companyId)
    .eq('status', 'open')
    .eq('job_channels.channel_key', 'careers')
    .eq('job_channels.status', 'live')
    .order('title')
  return (data ?? []) as JobRow[]
}

type Part = { field: string; value?: string; file?: { buffer: Buffer; filename: string; mimetype: string } }

/**
 * @fastify/multipart throws coded errors when a limit is hit while the body
 * streams; the client reads `{ error }`, so those become a 413 in that shape.
 */
export function multipartLimitMessage(e: unknown): string | null {
  const code = (e as { code?: string } | null)?.code
  if (code === 'FST_REQ_FILE_TOO_LARGE') return 'Your CV must be 10 MB or smaller.'
  if (code === 'FST_FILES_LIMIT') return 'Attach one CV only.'
  if (code === 'FST_FIELDS_LIMIT' || code === 'FST_PARTS_LIMIT') return 'The form sent too many fields.'
  return null
}

async function readParts(req: FastifyRequest): Promise<Part[]> {
  const parts: Part[] = []
  for await (const part of req.parts()) {
    if (part.type === 'file') {
      const buffer = await part.toBuffer()
      parts.push({ field: part.fieldname, file: { buffer, filename: part.filename, mimetype: part.mimetype } })
    } else {
      parts.push({ field: part.fieldname, value: String(part.value) })
    }
  }
  return parts
}

export async function registerCareersRoutes(app: FastifyInstance): Promise<void> {
  await app.register(multipart, { limits: { fileSize: CV_MAX_BYTES, files: 1, fields: 20 } })
  const supabaseUrl = requiredEnv('SUPABASE_URL')

  app.get<{ Params: { code: string } }>('/api/careers/:code', async (req, reply) => {
    const company = await findCompany(req.params.code)
    if (!company) return fail(reply, 404, 'No careers page for that company.')
    const jobs = await listedJobs(company.id)
    return {
      company: publicCompany(company, supabaseUrl),
      jobs: jobs.map((j) => ({ id: j.id, title: j.title, summary: summaryOf(j.description) })),
    }
  })

  app.get<{ Params: { code: string; jobId: string } }>('/api/careers/:code/jobs/:jobId', async (req, reply) => {
    const company = await findCompany(req.params.code)
    if (!company) return fail(reply, 404, 'No careers page for that company.')
    const job = (await listedJobs(company.id)).find((j) => j.id === req.params.jobId)
    if (!job) return fail(reply, 404, 'This role is not open for applications.')
    return { company: publicCompany(company, supabaseUrl), job: publicBrief(job) }
  })

  app.post<{ Params: { code: string; jobId: string } }>(
    '/api/careers/:code/jobs/:jobId/applications',
    async (req, reply) => {
      if (!req.isMultipart()) return fail(reply, 400, 'Send the application as a form with your CV attached.')
      // Before the body is read: the limit is there to bound the work an
      // abusive connection can cause, so it must not wait for a 10 MB upload.
      if (!ipLimiter.allow(`ip:${req.ip}`)) return fail(reply, 429, 'Too many applications from this connection. Try again later.')

      let parts: Part[]
      try {
        parts = await readParts(req)
      } catch (e) {
        const message = multipartLimitMessage(e)
        if (!message) throw e
        return fail(reply, 413, message)
      }
      const fields = Object.fromEntries(parts.filter((p) => p.value !== undefined).map((p) => [p.field, p.value]))
      const cv = parts.find((p) => p.field === 'cv' && p.file)?.file

      // Bots fill the hidden field. Say nothing; store nothing.
      if (isHoneypotTripped(fields)) return reply.status(201).send({ reference: referenceFor(randomUUID()) })

      const parsed = applicationInput.safeParse(fields)
      if (!parsed.success) return fail(reply, 400, parsed.error.issues[0]?.message ?? 'Check the form.')
      const input = parsed.data
      if (!cv) return fail(reply, 400, 'Attach your CV as a PDF or Word document.')
      const cvProblem = validateCv({ mimetype: cv.mimetype, size: cv.buffer.length, filename: cv.filename })
      if (cvProblem) return fail(reply, 400, cvProblem)

      const company = await findCompany(req.params.code)
      if (!company) return fail(reply, 404, 'No careers page for that company.')
      const job = (await listedJobs(company.id)).find((j) => j.id === req.params.jobId)
      if (!job) return fail(reply, 404, 'This role is not open for applications.')

      // The job's questions are the truth, not the form's.
      const checked = checkAnswers(job.screening_questions, input.answers)
      if (!checked.ok) return fail(reply, 400, checked.error)

      const db = serviceDb()

      // The budget check, the duplicate check and the inserts run one applicant
      // at a time (per email) so concurrent submissions cannot all pass the
      // checks; the database's one-open-application index is the guarantee
      // across processes.
      return serialised(`apply:${input.email}`, async () => {
        // Only accepted submissions spend the per-email budget (recorded once
        // the application is saved), so a retry after a validation error or a
        // transient failure is never locked out.
        if (!emailLimiter.peek(`email:${input.email}`)) {
          return fail(reply, 429, 'Too many applications for this email address. Try again later.')
        }

        // Duplicate rule across every candidate row carrying this email (the
        // column is not unique): one open application per person per role.
        const { data: priorApps } = await db
          .from('applications')
          .select('stage_key, candidate:candidates!inner(email)')
          .eq('job_id', job.id)
          .eq('candidate.email', input.email)
        if (isDuplicateApplication(priorApps ?? [])) {
          return fail(reply, 409, 'You have already applied for this role — we have your application.')
        }

        // Identity: reuse the oldest exact email match; applications stay separate.
        const { data: existingCandidate } = await db
          .from('candidates')
          .select('id')
          .eq('email', input.email)
          .order('created_at')
          .limit(1)
          .maybeSingle()

        let candidateId = existingCandidate?.id ?? null
        // Everything written for this submission, undone together if the CV
        // cannot be stored — a first-time applicant's candidate row included.
        const rollback = async (applicationId: string) => {
          await db.from('applications').delete().eq('id', applicationId)
          if (!existingCandidate && candidateId) await db.from('candidates').delete().eq('id', candidateId)
        }
        if (!candidateId) {
          const { data: created, error: candErr } = await db
            .from('candidates')
            .insert({ full_name: input.name, email: input.email, phone: input.phone || null })
            .select('id')
            .single()
          if (candErr || !created) {
            req.log.error({ err: candErr }, 'careers: candidate insert failed')
            return fail(reply, 500, 'We could not save your application. Please try again.')
          }
          candidateId = created.id
        }

        const { data: application, error: appErr } = await db
          .from('applications')
          .insert({
            job_id: job.id,
            company_id: company.id,
            candidate_id: candidateId,
            source_channel_key: 'careers',
            screening_answers: checked.answers,
          })
          .select('id')
          .single()
        if (appErr?.code === '23505') {
          return fail(reply, 409, 'You have already applied for this role — we have your application.')
        }
        if (appErr || !application) {
          req.log.error({ err: appErr }, 'careers: application insert failed')
          return fail(reply, 500, 'We could not save your application. Please try again.')
        }

        // The CV is part of the application: if it cannot be stored, the
        // application is taken back so the candidate can resubmit (the
        // one-open-application index would otherwise refuse the retry).
        const fileId = randomUUID()
        const path = `${application.id}/${fileId}.${cvExtension(cv.mimetype)}`
        const { error: uploadErr } = await db.storage
          .from('candidate-files')
          .upload(path, cv.buffer, { contentType: cv.mimetype })
        if (uploadErr) {
          req.log.error({ err: uploadErr }, 'careers: cv upload failed')
          await rollback(application.id)
          return fail(reply, 500, 'We could not store your CV. Please try again.')
        }
        const { error: fileErr } = await db.from('application_files').insert({
          id: fileId,
          application_id: application.id,
          company_id: company.id,
          kind: 'cv',
          storage_path: path,
          original_name: cv.filename.slice(0, 200),
          mime_type: cv.mimetype,
          size_bytes: cv.buffer.length,
        })
        if (fileErr) {
          req.log.error({ err: fileErr }, 'careers: application_files insert failed')
          await db.storage.from('candidate-files').remove([path])
          await rollback(application.id)
          return fail(reply, 500, 'We could not store your CV. Please try again.')
        }

        // What the form said, kept on the timeline: an existing candidate
        // record is reused by email, never silently overwritten.
        const submitted = existingCandidate
          ? ` Submitted as ${input.name}${input.phone ? `, ${input.phone}` : ''}.`
          : ''
        await db.from('application_events').insert({
          application_id: application.id,
          kind: 'note',
          body: `Applied through the ${company.name} careers page.${submitted}`,
        })

        emailLimiter.record(`email:${input.email}`)
        return reply.status(201).send({ reference: referenceFor(application.id) })
      })
    },
  )
}
