import type { FastifyInstance } from 'fastify'
import { createHash } from 'node:crypto'
import { createClient } from '@supabase/supabase-js'
import { z } from 'zod'
import { env, requiredEnv } from './env.js'
import { identityFromToken, serviceDb } from './supabaseAdmin.js'

const escape = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)
export function assignmentEmail(input: { candidate: string; role: string; action: string; due: string | null; url: string }): { subject: string; html: string } {
  return {
    subject: `Candidate action assigned: ${input.role}`,
    html: `<p>You have been assigned a candidate action for ${escape(input.role)}.</p><p>Candidate: ${escape(input.candidate)}<br>Next action: ${escape(input.action)}<br>Due: ${escape(input.due ?? 'Not set')}</p><p><a href="${escape(input.url)}">Open candidate</a></p>`,
  }
}

export function registerCandidateNotifications(app: FastifyInstance): void {
  app.post('/api/hiring/notify-assignment', async (req, reply) => {
    const parsed = z.object({ applicationId: z.string().uuid(), version: z.string().max(80) }).safeParse(req.body)
    if (!parsed.success) return reply.code(400).send({ message: 'Application and saved version are required.' })
    const token = req.headers.authorization?.replace(/^Bearer\s+/i, '')
    const caller = token ? await identityFromToken(token) : null
    if (!caller || caller.mustChangePassword) return reply.code(401).send({ message: 'Sign in to send assignment notifications.' })
    // Read using the caller's JWT so company visibility and password gates remain authoritative.
    const db = createClient(requiredEnv('SUPABASE_URL'), env('SUPABASE_PUBLISHABLE_KEY') ?? requiredEnv('VITE_SUPABASE_PUBLISHABLE_KEY'), {
      global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: person } = await db.from('people').select('id').eq('user_id', caller.id).maybeSingle()
    if (!person) return reply.code(403).send({ message: 'Your account is not linked to an employee record.' })
    const { data: row, error } = await db.from('applications').select('id, company_id, owner_id, stage_key, next_action, next_action_due, updated_at, candidate:candidates(full_name), job:jobs(title)').eq('id', parsed.data.applicationId).maybeSingle()
    if (error || !row) return reply.code(404).send({ message: 'Candidate not visible with your access.' })
    const admin = serviceDb()
    async function mayReview(personId: string): Promise<boolean> {
      const [a, g] = await Promise.all([
        admin.from('platform_admins').select('person_id').eq('person_id', personId).maybeSingle(),
        admin.from('access_grants').select('grant_capabilities(capability_key)').eq('person_id', personId).eq('company_id', row!.company_id),
      ])
      return Boolean(a.data) || (g.data ?? []).some(grant => grant.grant_capabilities.some(c => c.capability_key === 'candidates.review'))
    }
    if (!(await mayReview(person.id))) return reply.code(403).send({ message: 'Candidate review permission is required.' })
    const age = Date.now() - Date.parse(row.updated_at)
    // Restrict sends to the fresh save; provider deduplication outlives this window.
    if (row.updated_at !== parsed.data.version || !Number.isFinite(age) || age > 10 * 60_000 || age < -60_000 || ['hired', 'rejected', 'withdrawn'].includes(row.stage_key)) return reply.code(409).send({ message: 'Assignment changed, closed, or is no longer a fresh save; no email sent. Refresh the candidate.' })
    if (!row.owner_id || !row.next_action) return { emailSent: false, message: 'No owner or next action selected; no email sent.' }
    const { data: owner } = await admin.from('people').select('work_email, user_id').eq('id', row.owner_id).is('archived_at', null).maybeSingle()
    if (!owner?.user_id || !(await mayReview(row.owner_id))) return { emailSent: false, message: 'Email not sent: the owner needs an account and candidate review access for this company. Ask an administrator to check access.' }
    if (!owner.work_email) return { emailSent: false, message: 'Email not sent: the owner has no work email. Please contact them directly.' }
    const key = env('RESEND_API_KEY'), from = env('EMAIL_FROM'), base = env('APP_BASE_URL')
    if (!key || !from || !base) return { emailSent: false, message: 'Assignment saved to the owner’s Home queue. Email delivery is not configured; please contact them directly.' }
    const candidate = row.candidate as unknown as { full_name: string } | null
    const job = row.job as unknown as { title: string } | null
    const message = assignmentEmail({ candidate: candidate?.full_name ?? 'Candidate', role: job?.title ?? 'Role', action: row.next_action, due: row.next_action_due, url: `${base.replace(/\/+$/, '')}/hiring/applications/${row.id}` })
    try {
      const response = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        // One mail per owner and next action, however many times the record is saved.
        headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Idempotency-Key': `candidate-${createHash('sha256').update(`${row.id}:${row.owner_id}:${row.next_action}`).digest('hex')}` },
        body: JSON.stringify({ from, to: [owner.work_email], ...message }), signal: AbortSignal.timeout(10000),
      })
      if (!response.ok) throw new Error(`Email provider returned ${response.status}`)
      return { emailSent: true }
    } catch {
      return { emailSent: false, message: 'Assignment saved to the owner’s Home queue, but email delivery could not be confirmed. Please contact them directly.' }
    }
  })
}
