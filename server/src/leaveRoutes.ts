import type { FastifyInstance, FastifyRequest } from 'fastify'
import { z } from 'zod'
import { identityFromToken, serviceDb } from './supabaseAdmin.js'
import { NotifyThrottle, buildLeaveEmail, eventMatchesRequest, leaveRecipients, sendLeaveEmail, type LeaveEvent } from './leaveEmails.js'

const throttle = new NotifyThrottle(10 * 60_000)

/**
 * POST /api/leave/notify — the app calls it after request_leave /
 * decide_leave / request_leave_cancellation succeeded. The database already
 * decided the action; this only tells people. The caller must be the
 * request's person or someone who may approve leave in that company, so a
 * stranger cannot make the service mail about somebody else's request.
 * Approvers = the company's HR contact when set, else everyone holding
 * leave.approve there. Delivery failure is reported, never thrown.
 */

const body = z.object({
  requestId: z.string().uuid(),
  event: z.enum(['submitted', 'approved', 'rejected', 'cancellation_asked']),
})

async function callerPersonId(req: FastifyRequest): Promise<string | null> {
  const token = req.headers.authorization?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const identity = await identityFromToken(token)
  if (!identity) return null
  const { data } = await serviceDb().from('people').select('id').eq('user_id', identity.id).maybeSingle()
  return data?.id ?? null
}

async function approverEmails(companyId: string): Promise<string[]> {
  const db = serviceDb()
  const { data: company } = await db
    .from('companies')
    .select('hr_contact:people!companies_hr_contact_person_id_fkey(work_email)')
    .eq('id', companyId)
    .maybeSingle()
  const hr = (company?.hr_contact as unknown as { work_email: string | null } | null)?.work_email
  if (hr) return [hr]
  const { data: grants } = await db
    .from('access_grants')
    .select('person:people!access_grants_person_id_fkey(work_email), grant_capabilities!inner(capability_key)')
    .eq('company_id', companyId)
    .eq('grant_capabilities.capability_key', 'leave.approve')
  return [...new Set((grants ?? []).map((g) => (g.person as unknown as { work_email: string | null } | null)?.work_email).filter((e): e is string => !!e))]
}

async function mayNotify(personId: string, requestPersonId: string, companyId: string): Promise<boolean> {
  if (personId === requestPersonId) return true
  const db = serviceDb()
  const { data: admin } = await db.from('platform_admins').select('person_id').eq('person_id', personId).maybeSingle()
  if (admin) return true
  const { data: grant } = await db
    .from('access_grants')
    .select('id, grant_capabilities!inner(capability_key)')
    .eq('person_id', personId)
    .eq('company_id', companyId)
    .eq('grant_capabilities.capability_key', 'leave.approve')
    .maybeSingle()
  return grant !== null
}

export function registerLeaveRoutes(app: FastifyInstance): void {
  app.post('/api/leave/notify', async (req, reply) => {
    const parsed = body.safeParse(req.body)
    if (!parsed.success) return reply.status(400).send({ error: 'requestId and event are required.' })
    const personId = await callerPersonId(req)
    if (!personId) return reply.status(401).send({ error: 'Sign in to continue.' })

    const db = serviceDb()
    const { data: r } = await db
      .from('leave_requests')
      .select(
        `id, person_id, company_id, status, cancellation_requested_at, cancellation_declined_at, start_date, end_date, working_days, note, decision_note, cancellation_request_reason,
         person:people!leave_requests_person_id_fkey(full_name, work_email), company:companies(name), leave_type:leave_types(label)`,
      )
      .eq('id', parsed.data.requestId)
      .maybeSingle()
    if (!r) return reply.status(404).send({ error: 'Leave request not found.' })
    if (!(await mayNotify(personId, r.person_id, r.company_id))) return reply.status(403).send({ error: 'Not your request.' })

    const event = parsed.data.event as LeaveEvent
    if (!eventMatchesRequest(event, r)) return reply.status(409).send({ error: 'That is not what the request shows.' })
    if (!throttle.allow(r.id, event)) return { emailSent: false, recipients: 0, throttled: true }
    const person = r.person as unknown as { full_name: string; work_email: string | null } | null
    const { data: balance } = await db.rpc('leave_balance', {
      p_person_id: r.person_id,
      p_company_id: r.company_id,
      p_year: Number(String(r.start_date).slice(0, 4)),
    })
    const remaining = (balance as { exists?: boolean; remaining?: number } | null)?.exists ? Number((balance as { remaining?: number }).remaining ?? 0) : null
    const input = {
      personName: person?.full_name ?? 'Someone',
      personEmail: person?.work_email ?? null,
      companyName: (r.company as unknown as { name: string } | null)?.name ?? '',
      leaveType: (r.leave_type as unknown as { label: string } | null)?.label ?? 'Leave',
      startDate: String(r.start_date),
      endDate: String(r.end_date),
      workingDays: Number(r.working_days),
      remaining,
      note: event === 'cancellation_asked' ? r.cancellation_request_reason : r.note,
      decisionNote: r.decision_note,
    }
    const to = leaveRecipients(event, input, event === 'submitted' || event === 'cancellation_asked' ? await approverEmails(r.company_id) : [])
    const message = buildLeaveEmail(event, input)
    const emailSent = await sendLeaveEmail(to, message)
      .then(() => true)
      .catch((error: unknown) => {
        console.warn(`[leave-notify] ${event} for ${r.id} not delivered:`, error instanceof Error ? error.message : error)
        return false
      })
    return { emailSent, recipients: to.length }
  })
}
