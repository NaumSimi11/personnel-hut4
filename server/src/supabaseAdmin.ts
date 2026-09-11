import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { env, requiredEnv } from './env.js'

/**
 * Server-side Supabase Auth wrapper — the ONLY file that talks to Supabase
 * with the secret key. Ported from the Hut4 leave system's supabaseAuth.ts,
 * with one deliberate change: the must-change flag lives in app_metadata
 * (admin-API-writable only), because in this app the browser holds a Supabase
 * session and user_metadata would be user-editable.
 */

export type SupabaseIdentity = {
  id: string
  email: string
  mustChangePassword: boolean
}

let _anon: SupabaseClient | null = null
let _admin: SupabaseClient | null = null

// Password verification uses the publishable key: it exercises the same
// GoTrue rate limiting a public client would get.
function anonClient(): SupabaseClient {
  if (!_anon) {
    // The frontend's VITE_-prefixed variable is the same public key.
    const key = env('SUPABASE_PUBLISHABLE_KEY') ?? requiredEnv('VITE_SUPABASE_PUBLISHABLE_KEY')
    _anon = createClient(requiredEnv('SUPABASE_URL'), key, {
      auth: { persistSession: false, autoRefreshToken: false },
    })
  }
  return _anon
}

// Account creation and password administration need the secret key.
function adminClient(): SupabaseClient {
  if (!_admin) {
    _admin = createClient(requiredEnv('SUPABASE_URL'), requiredEnv('SUPABASE_SECRET_KEY'), {
      auth: { persistSession: false, autoRefreshToken: false },
    })
  }
  return _admin
}

/** The admin client doubles as the RLS-bypassing data client for people rows. */
export function serviceDb(): SupabaseClient {
  return adminClient()
}

/** Resolve a caller's JWT to their identity. Null when invalid/expired. */
export async function identityFromToken(token: string): Promise<SupabaseIdentity | null> {
  const { data, error } = await adminClient().auth.getUser(token)
  if (error || !data.user?.email) return null
  return {
    id: data.user.id,
    email: data.user.email,
    mustChangePassword: data.user.app_metadata?.must_change_password === true,
  }
}

/** Verify email+password. Returns null on any failure — callers must not learn why. */
export async function verifyPassword(
  email: string,
  password: string,
): Promise<SupabaseIdentity | null> {
  const { data, error } = await anonClient().auth.signInWithPassword({ email, password })
  if (error || !data.user?.email) return null
  return {
    id: data.user.id,
    email: data.user.email,
    mustChangePassword: data.user.app_metadata?.must_change_password === true,
  }
}

/** Create an invited account with a temp password that must be changed on first login. */
export async function createInvitedAccount(input: {
  email: string
  name: string
  tempPassword: string
}): Promise<{ id: string }> {
  const { data, error } = await adminClient().auth.admin.createUser({
    email: input.email,
    password: input.tempPassword,
    email_confirm: true, // invite-only: the admin vouches for the address
    user_metadata: { name: input.name },
    app_metadata: { must_change_password: true },
  })
  if (error || !data.user)
    throw new Error(`Supabase account creation failed: ${error?.message ?? 'no user returned'}`)
  return { id: data.user.id }
}

/** Set a new password and clear the must-change flag, atomically from the app's view. */
export async function setPassword(supabaseUserId: string, newPassword: string): Promise<void> {
  const { error } = await adminClient().auth.admin.updateUserById(supabaseUserId, {
    password: newPassword,
    app_metadata: { must_change_password: false },
  })
  if (error) throw new Error(`Supabase password update failed: ${error.message}`)
}

/**
 * Put an account back on a temporary password that must be replaced at the
 * next login. Used for "resend the invitation" and "they forgot it" alike —
 * both are the same operation, so there is exactly one way an account can be
 * handed back to its owner.
 */
export async function resetToTempPassword(
  supabaseUserId: string,
  tempPassword: string,
): Promise<void> {
  const { error } = await adminClient().auth.admin.updateUserById(supabaseUserId, {
    password: tempPassword,
    app_metadata: { must_change_password: true },
  })
  if (error) throw new Error(`Supabase password reset failed: ${error.message}`)
}

/**
 * Find an existing Supabase account by address. The admin API has no
 * get-by-email, so this pages listUsers; at this org's size that is one call.
 */
export async function findAccountByEmail(email: string): Promise<{ id: string } | null> {
  const wanted = email.trim().toLowerCase()
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await adminClient().auth.admin.listUsers({ page, perPage: 200 })
    if (error) throw new Error(`Supabase account lookup failed: ${error.message}`)
    const match = data.users.find((user) => user.email?.trim().toLowerCase() === wanted)
    if (match) return { id: match.id }
    if (data.users.length < 200) return null
  }
  return null
}

/** Delete an auth account entirely — used only by test cleanup endpoints/tools. */
export async function deleteAccount(supabaseUserId: string): Promise<void> {
  const { error } = await adminClient().auth.admin.deleteUser(supabaseUserId)
  if (error) throw new Error(`Supabase account deletion failed: ${error.message}`)
}
