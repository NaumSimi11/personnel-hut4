import { supabase } from '@/lib/supabase'

/**
 * Client for the privileged auth endpoints in ../server (invite, reset,
 * change password). They authenticate the caller by Supabase access token.
 */

async function call<T>(path: string, body: unknown): Promise<T> {
  const { data } = await supabase.auth.getSession()
  const token = data.session?.access_token
  if (!token) throw new Error('Sign in to continue.')
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  })
  const payload = (await response.json().catch(() => ({}))) as { error?: string } & T
  if (!response.ok) throw new Error(payload.error ?? `Request failed (${response.status}).`)
  return payload
}

export type AccessCredential = { tempPassword: string; emailSent: boolean }

export function inviteUser(input: {
  email: string
  name: string
}): Promise<AccessCredential & { personId: string }> {
  return call('/api/auth/invite', input)
}

export function resetAccess(personId: string): Promise<AccessCredential & { email: string }> {
  return call('/api/auth/reset-access', { personId })
}

export function changePassword(input: {
  currentPassword: string
  newPassword: string
}): Promise<{ success: boolean }> {
  return call('/api/auth/change-password', input)
}
