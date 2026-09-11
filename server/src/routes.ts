import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import { z } from 'zod'
import { meetsPasswordPolicy, PASSWORD_POLICY_SUMMARY } from '../../shared/passwordPolicy.js'
import { generateTempPassword, isAllowedEmail, parseAllowedDomains } from './account.js'
import { sendAccessEmail } from './emails.js'
import { env } from './env.js'
import {
  createInvitedAccount,
  findAccountByEmail,
  identityFromToken,
  resetToTempPassword,
  serviceDb,
  setPassword,
  verifyPassword,
  type SupabaseIdentity,
} from './supabaseAdmin.js'

/**
 * The three privileged auth operations, ported from the Hut4 leave system:
 * invite, reset-access (one operation for "never got it" and "forgot it"),
 * and change-password (re-verifies the current password so a stolen session
 * alone cannot rotate it). Everything else the app does goes straight from
 * the browser to Supabase under RLS — these endpoints exist only because
 * they need the secret key.
 */

type Caller = { identity: SupabaseIdentity; personId: string | null; isAdmin: boolean }

async function resolveCaller(req: FastifyRequest): Promise<Caller | null> {
  const token = req.headers.authorization?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const identity = await identityFromToken(token)
  if (!identity) return null
  const db = serviceDb()
  const { data: person } = await db
    .from('people')
    .select('id')
    .eq('user_id', identity.id)
    .maybeSingle()
  let isAdmin = false
  if (person) {
    const { data: admin } = await db
      .from('platform_admins')
      .select('person_id')
      .eq('person_id', person.id)
      .maybeSingle()
    isAdmin = admin !== null
  }
  return { identity, personId: person?.id ?? null, isAdmin }
}

function fail(reply: FastifyReply, status: number, message: string) {
  return reply.status(status).send({ error: message })
}

/** Mail failure never breaks the action that caused it. */
async function deliverAccessEmail(input: {
  name: string
  email: string
  tempPassword: string
  kind: 'invite' | 'reset'
}): Promise<boolean> {
  try {
    await sendAccessEmail(input)
    return true
  } catch (error) {
    console.warn(
      `[Account] Could not email the ${input.kind} for ${input.email}:`,
      error instanceof Error ? error.message : error,
    )
    return false
  }
}

const inviteInput = z.object({
  email: z.string().trim().toLowerCase().email().max(320),
  name: z.string().trim().min(2).max(120),
})

const resetInput = z.object({ personId: z.string().uuid() })

const changePasswordInput = z.object({
  currentPassword: z.string().min(1).max(200),
  newPassword: z.string().min(12).max(200).refine(meetsPasswordPolicy, PASSWORD_POLICY_SUMMARY),
})

export function registerRoutes(app: FastifyInstance): void {
  app.get('/api/health', async () => ({ ok: true }))

  app.post('/api/auth/invite', async (req, reply) => {
    const caller = await resolveCaller(req)
    if (!caller) return fail(reply, 401, 'Sign in to continue.')
    if (!caller.isAdmin) return fail(reply, 403, 'Only platform admins can invite.')
    const parsed = inviteInput.safeParse(req.body)
    if (!parsed.success) return fail(reply, 400, parsed.error.issues[0]?.message ?? 'Invalid input.')
    const input = parsed.data

    const domains = parseAllowedDomains(env('COMPANY_EMAIL_DOMAINS'))
    if (!isAllowedEmail(input.email, domains)) {
      return fail(
        reply,
        400,
        `Only company addresses can be invited (${domains.join(', ') || 'no domains configured'}).`,
      )
    }
    const db = serviceDb()
    const { data: existing } = await db
      .from('people')
      .select('id')
      .eq('work_email', input.email)
      .maybeSingle()
    if (existing) return fail(reply, 400, 'An account with this email already exists.')
    if (await findAccountByEmail(input.email))
      return fail(reply, 400, 'An account with this email already exists.')

    const tempPassword = generateTempPassword()
    const account = await createInvitedAccount({ ...input, tempPassword })
    const { data: person, error: personErr } = await db
      .from('people')
      .insert({ user_id: account.id, full_name: input.name, work_email: input.email })
      .select('id')
      .single()
    if (personErr) return fail(reply, 500, `Account created but person record failed: ${personErr.message}`)

    const emailSent = await deliverAccessEmail({ ...input, tempPassword, kind: 'invite' })
    // The temp password is ALSO returned once, to the inviting admin, so a
    // failed or slow email never leaves an invitee stranded. It is useless
    // after first login (forced change) and is never stored.
    return { personId: person.id, tempPassword, emailSent }
  })

  app.post('/api/auth/reset-access', async (req, reply) => {
    const caller = await resolveCaller(req)
    if (!caller) return fail(reply, 401, 'Sign in to continue.')
    if (!caller.isAdmin) return fail(reply, 403, 'Only platform admins can reset access.')
    const parsed = resetInput.safeParse(req.body)
    if (!parsed.success) return fail(reply, 400, 'Invalid input.')

    const db = serviceDb()
    const { data: target } = await db
      .from('people')
      .select('id, full_name, work_email, user_id, archived_at')
      .eq('id', parsed.data.personId)
      .maybeSingle()
    if (!target) return fail(reply, 404, 'Person not found.')
    if (!target.work_email)
      return fail(reply, 400, 'This person has no work email to send a password to.')
    if (target.archived_at)
      return fail(reply, 400, 'Restore this person before issuing a new password.')

    const tempPassword = generateTempPassword()
    let accountId = target.user_id as string | null
    if (!accountId) accountId = (await findAccountByEmail(target.work_email))?.id ?? null
    if (accountId) {
      await resetToTempPassword(accountId, tempPassword)
    } else {
      const created = await createInvitedAccount({
        email: target.work_email,
        name: target.full_name,
        tempPassword,
      })
      accountId = created.id
    }
    if (target.user_id !== accountId)
      await db.from('people').update({ user_id: accountId }).eq('id', target.id)

    const emailSent = await deliverAccessEmail({
      name: target.full_name,
      email: target.work_email,
      tempPassword,
      kind: 'reset',
    })
    return { tempPassword, emailSent, email: target.work_email }
  })

  app.post('/api/auth/change-password', async (req, reply) => {
    const caller = await resolveCaller(req)
    if (!caller) return fail(reply, 401, 'Sign in to continue.')
    const parsed = changePasswordInput.safeParse(req.body)
    if (!parsed.success) return fail(reply, 400, parsed.error.issues[0]?.message ?? 'Invalid input.')
    if (parsed.data.newPassword === parsed.data.currentPassword)
      return fail(reply, 400, 'Choose a password you have not used here before.')

    // Re-verify the current password so a stolen session alone cannot rotate it.
    const identity = await verifyPassword(caller.identity.email, parsed.data.currentPassword)
    if (!identity || identity.id !== caller.identity.id)
      return fail(reply, 401, 'The current password is incorrect.')

    await setPassword(identity.id, parsed.data.newPassword)
    return { success: true }
  })
}
