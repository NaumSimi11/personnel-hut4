import type { FastifyInstance, FastifyRequest } from 'fastify'
import { createHash } from 'node:crypto'
import { z } from 'zod'
import { env } from './env.js'
import { identityFromToken, serviceDb } from './supabaseAdmin.js'
import { buildManagerEmail, managerEventMatches, type ManagerEvent } from './hiringEmails.js'

/**
 * POST /api/hiring/notify-manager — the app calls it after a request with a
 * hiring manager was submitted (or resubmitted) or approved. The database
 * action has already happened; this only tells the manager. The caller must
 * be the requester, an approver in the company, or an admin; the event must
 * match the record; the mail goes once per request and event (provider
 * idempotency key), so a retry never doubles it. Every failure is reported,
 * never thrown — the request stays saved regardless.
 */

const body = z.object({
  requestId: z.string().uuid(),
  event: z.enum(['assigned', 'approved']),
})

async function callerPersonId(req: FastifyRequest): Promise<string | null> {
  const token = req.headers.authorization?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const identity = await identityFromToken(token)
  if (!identity || identity.mustChangePassword) return null
  const { data } = await serviceDb().from('people').select('id').eq('user_id', identity.id).maybeSingle()
  return data?.id ?? null
}

async function hasCapability(personId: string, companyId: string, capability: string): Promise<boolean> {
  const db = serviceDb()
  const { data: admin } = await db.from('platform_admins').select('person_id').eq('person_id', personId).maybeSingle()
  if (admin) return true
  const { data: grant } = await db
    .from('access_grants')
    .select('id, grant_capabilities!inner(capability_key)')
    .eq('person_id', personId)
    .eq('company_id', companyId)
    .eq('grant_capabilities.capability_key', capability)
    .maybeSingle()
  return grant !== null
}

export function registerHiringRoutes(app: FastifyInstance): void {
  app.post('/api/hiring/notify-manager', async (req, reply) => {
    const parsed = body.safeParse(req.body)
    if (!parsed.success) return reply.status(400).send({ error: 'requestId and event are required.' })
    const personId = await callerPersonId(req)
    if (!personId) return reply.status(401).send({ error: 'Sign in to continue.' })

    const db = serviceDb()
    const { data: r } = await db
      .from('hiring_requests')
      .select(
        `id, company_id, title, status, hiring_manager_id, requested_by, decided_by, target_start_date,
         company:companies(name), requester:people!hiring_requests_requested_by_fkey(full_name),
         decider:people!hiring_requests_decided_by_fkey(full_name),
         manager:people!hiring_requests_hiring_manager_id_fkey(full_name, work_email, user_id, archived_at)`,
      )
      .eq('id', parsed.data.requestId)
      .maybeSingle()
    if (!r) return reply.status(404).send({ error: 'Hiring request not found.' })
    const allowed = r.requested_by === personId || (await hasCapability(personId, r.company_id, 'jobs.approve')) || (await hasCapability(personId, r.company_id, 'jobs.edit'))
    if (!allowed) return reply.status(403).send({ error: 'Not your request.' })

    const event = parsed.data.event as ManagerEvent
    if (!managerEventMatches(event, r)) return reply.status(409).send({ error: 'That is not what the request shows.' })
    const manager = r.manager as unknown as { full_name: string; work_email: string | null; user_id: string | null; archived_at: string | null } | null
    if (!manager || manager.archived_at) return { emailSent: false, message: 'The hiring manager record is archived; nobody was notified.' }
    // Assigning a manager grants nothing: the in-app row and the link only work with jobs.view in the company.
    const canOpen = await hasCapability(r.hiring_manager_id!, r.company_id, 'jobs.view')
    const accessNote = canOpen ? '' : ` ${manager.full_name} cannot open hiring in ${(r.company as unknown as { name: string } | null)?.name ?? 'this company'} yet — grant jobs.view for the link to work.`
    if (!manager.work_email) return { emailSent: false, message: `${manager.full_name} has no work email on record; tell them directly.${accessNote}` }
    const key = env('RESEND_API_KEY')
    const from = env('EMAIL_FROM')
    const base = env('APP_BASE_URL')?.replace(/\/+$/, '')
    if (!key || !from || !base) return { emailSent: false, message: `Email delivery is not configured; ${manager.full_name} sees it on their Home page.${accessNote}` }

    const message = buildManagerEmail(event, {
      role: r.title,
      company: (r.company as unknown as { name: string } | null)?.name ?? '',
      requester: (r.requester as unknown as { full_name: string } | null)?.full_name ?? null,
      approver: (r.decider as unknown as { full_name: string } | null)?.full_name ?? null,
      targetStart: r.target_start_date,
      url: `${base}/hiring`,
    })
    try {
      const response = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${key}`,
          'Content-Type': 'application/json',
          // One mail per request, event and manager — a retry after a failure is safe.
          'Idempotency-Key': `hiring-manager-${createHash('sha256').update(`${r.id}:${event}:${r.hiring_manager_id}`).digest('hex')}`,
        },
        body: JSON.stringify({ from, to: [manager.work_email], subject: message.subject, html: message.html }),
        signal: AbortSignal.timeout(10_000),
      })
      if (!response.ok) throw new Error(`Resend responded ${response.status}`)
      return { emailSent: true, message: `${manager.full_name} was emailed.${accessNote}` }
    } catch (error: unknown) {
      console.warn(`[hiring-notify] ${event} for ${r.id} not delivered:`, error instanceof Error ? error.message : error)
      return { emailSent: false, message: `The email to ${manager.full_name} could not be delivered; tell them directly or retry from the request.${accessNote}` }
    }
  })
}
