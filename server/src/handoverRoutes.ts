import type { FastifyInstance } from 'fastify'
import { env } from './env.js'
import { identityFromToken, serviceDb } from './supabaseAdmin.js'
import { renderHandoverEmail, type HandoverField } from './handoverEmails.js'

/**
 * POST /api/handover/deliver — sends the pending handover emails (plan
 * 048). The database built each row: the recipient, the address, exactly
 * the fields they may have. This is the one place the mail leaves from;
 * the outcome lands on the row (sent, failed after five tries, or left
 * pending while mail is not configured) so HR sees green or red.
 */

const BATCH = 50
const MAX_ATTEMPTS = 5
let running = false

type Row = {
  id: string
  event: string
  recipient_label: string
  to_email: string | null
  fields: Record<string, HandoverField>
  stripped: string[]
  attempts: number
}

export async function deliverPendingHandover(): Promise<{ sent: number; failed: number; pending: number }> {
  const db = serviceDb()
  const key = env('RESEND_API_KEY')
  const from = env('EMAIL_FROM')
  const { data: rows, error } = await db
    .from('handover_sends')
    .select('id, event, recipient_label, to_email, fields, stripped, attempts')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
    .limit(BATCH)
  if (error) throw new Error(error.message)
  const list = (rows ?? []) as Row[]
  const result = { sent: 0, failed: 0, pending: 0 }
  for (const s of list) {
    if (!s.to_email) {
      // The database marks a missing address as `missing`; a pending row without one is a stale build.
      await db.from('handover_sends').update({ status: 'missing', missing: [`Address for ${s.recipient_label}`] }).eq('id', s.id)
      continue
    }
    if (!key || !from) {
      result.pending += 1
      continue
    }
    const message = renderHandoverEmail(s)
    try {
      const response = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Idempotency-Key': `handover-${s.id}-${s.attempts}` },
        body: JSON.stringify({ from, to: [s.to_email], subject: message.subject, html: message.html }),
        signal: AbortSignal.timeout(10_000),
      })
      if (!response.ok) throw new Error(`Resend responded ${response.status}`)
      await db.from('handover_sends').update({ status: 'sent', sent_at: new Date().toISOString(), attempts: s.attempts + 1, error: null }).eq('id', s.id)
      result.sent += 1
    } catch (e) {
      const attempts = s.attempts + 1
      const message_ = e instanceof Error ? e.message : String(e)
      console.warn(`[handover] ${s.event} ${s.id} not delivered (attempt ${attempts}):`, message_)
      await db
        .from('handover_sends')
        .update({ status: attempts >= MAX_ATTEMPTS ? 'failed' : 'pending', attempts, error: message_ })
        .eq('id', s.id)
      if (attempts >= MAX_ATTEMPTS) result.failed += 1
      else result.pending += 1
    }
  }
  return result
}

export function registerHandoverRoutes(app: FastifyInstance): void {
  app.post('/api/handover/deliver', async (req, reply) => {
    const token = req.headers.authorization?.replace(/^Bearer\s+/i, '')
    const identity = token ? await identityFromToken(token) : null
    if (!identity || identity.mustChangePassword) return reply.status(401).send({ error: 'Sign in to continue.' })
    if (running) return { sent: 0, failed: 0, pending: 0, busy: true }
    running = true
    try {
      return { ...(await deliverPendingHandover()), configured: Boolean(env('RESEND_API_KEY') && env('EMAIL_FROM')) }
    } catch (e) {
      console.error('[handover] delivery failed:', e instanceof Error ? e.message : e)
      return reply.status(500).send({ error: 'Delivery failed; the sends are still queued.' })
    } finally {
      running = false
    }
  })
}
