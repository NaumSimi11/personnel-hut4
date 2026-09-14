import type { FastifyInstance } from 'fastify'
import { env } from './env.js'
import { identityFromToken, serviceDb } from './supabaseAdmin.js'
import { renderNotificationEmail } from './notificationEmails.js'

/**
 * POST /api/notifications/deliver — sends the queued notification emails
 * (plan 043). The database already created the rows; this is the one place
 * mail leaves from. Any signed-in person may kick it (the app does after an
 * action and on Home), it delivers whatever is pending, and the outcome is
 * recorded on each row: sent, failed (with the error, retried next kick up
 * to five times), or skipped when delivery is not configured — visible to
 * the sender in the app, never silently lost.
 */

const BATCH = 50
const MAX_ATTEMPTS = 5
let running = false

type Row = {
  id: string
  kind: string
  title: string
  body: string | null
  link: string | null
  email_to: string | null
  email_attempts: number
  dedupe_key: string
}

export async function deliverPending(): Promise<{ sent: number; failed: number; skipped: number; pending: number }> {
  const db = serviceDb()
  const key = env('RESEND_API_KEY')
  const from = env('EMAIL_FROM')
  const base = env('APP_BASE_URL')
  const { data: rows, error } = await db
    .from('notifications')
    .select('id, kind, title, body, link, email_to, email_attempts, dedupe_key')
    .eq('email_status', 'pending')
    .order('created_at', { ascending: true })
    .limit(BATCH)
  if (error) throw new Error(error.message)
  const list = (rows ?? []) as Row[]
  const result = { sent: 0, failed: 0, skipped: 0, pending: 0 }
  for (const n of list) {
    if (!n.email_to) {
      await db.from('notifications').update({ email_status: 'skipped', email_error: 'no address' }).eq('id', n.id)
      result.skipped += 1
      continue
    }
    if (!key || !from) {
      // Not configured: the row waits (it shows in the app meanwhile) — nothing is lost, and
      // once the keys exist the next kick sends the backlog.
      result.pending += 1
      continue
    }
    const message = renderNotificationEmail(n, base)
    try {
      const response = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Idempotency-Key': `notification-${n.id}` },
        body: JSON.stringify({ from, to: [n.email_to], subject: message.subject, html: message.html }),
        signal: AbortSignal.timeout(10_000),
      })
      if (!response.ok) throw new Error(`Resend responded ${response.status}`)
      await db.from('notifications').update({ email_status: 'sent', email_sent_at: new Date().toISOString(), email_attempts: n.email_attempts + 1, email_error: null }).eq('id', n.id)
      result.sent += 1
    } catch (e) {
      const attempts = n.email_attempts + 1
      const message_ = e instanceof Error ? e.message : String(e)
      console.warn(`[notifications] ${n.kind} ${n.id} not delivered (attempt ${attempts}):`, message_)
      await db
        .from('notifications')
        .update({ email_status: attempts >= MAX_ATTEMPTS ? 'failed' : 'pending', email_attempts: attempts, email_error: message_ })
        .eq('id', n.id)
      if (attempts >= MAX_ATTEMPTS) result.failed += 1
      else result.pending += 1
    }
  }
  return result
}

export function registerNotificationRoutes(app: FastifyInstance): void {
  app.post('/api/notifications/deliver', async (req, reply) => {
    const token = req.headers.authorization?.replace(/^Bearer\s+/i, '')
    const identity = token ? await identityFromToken(token) : null
    if (!identity || identity.mustChangePassword) return reply.status(401).send({ error: 'Sign in to continue.' })
    if (running) return { sent: 0, failed: 0, skipped: 0, pending: 0, busy: true }
    running = true
    try {
      return { ...(await deliverPending()), configured: Boolean(env('RESEND_API_KEY') && env('EMAIL_FROM')) }
    } catch (e) {
      console.error('[notifications] delivery failed:', e instanceof Error ? e.message : e)
      return reply.status(500).send({ error: 'Delivery failed; the notifications are still queued.' })
    } finally {
      running = false
    }
  })
}
