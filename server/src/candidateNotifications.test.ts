import Fastify from 'fastify'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const state = vi.hoisted(() => ({
  identity: { id: 'user', mustChangePassword: false } as { id: string; mustChangePassword: boolean } | null,
  senderAllowed: true, ownerAllowed: true, version: '', stage: 'screening',
}))

function fakeDb(privileged: boolean) {
  return { from(table: string) {
    let personId = ''
    const result = () => ({ data: table === 'people' ? privileged ? { work_email: 'owner@example.test', user_id: 'owner-user' } : { id: 'sender' }
      : table === 'applications' ? { id: '00000000-0000-4000-8000-000000000001', company_id: 'company', owner_id: 'owner', stage_key: state.stage, next_action: 'Phone <screen>', next_action_due: '2026-10-01', updated_at: state.version, candidate: { full_name: '<Candidate>' }, job: { title: 'Developer' } }
      : table === 'platform_admins' ? null
      : [{ grant_capabilities: (personId === 'sender' ? state.senderAllowed : state.ownerAllowed) ? [{ capability_key: 'candidates.review' }] : [] }], error: null })
    const chain = { select: () => chain, eq: (key: string, value: string) => { if (key === 'person_id') personId = value; return chain }, is: () => chain, maybeSingle: async () => result(), then: (resolve: (value: unknown) => void) => Promise.resolve(result()).then(resolve) }
    return chain
  } }
}
vi.mock('@supabase/supabase-js', () => ({ createClient: () => fakeDb(false) }))
vi.mock('./supabaseAdmin.js', () => ({ identityFromToken: async () => state.identity, serviceDb: () => fakeDb(true) }))
vi.mock('./env.js', () => ({ env: (key: string) => key === 'APP_BASE_URL' ? 'https://hr.example.test' : 'configured', requiredEnv: () => 'configured' }))
import { registerCandidateNotifications } from './candidateNotifications.js'

beforeEach(() => {
  state.identity = { id: 'user', mustChangePassword: false }
  state.senderAllowed = true; state.ownerAllowed = true; state.stage = 'screening'; state.version = new Date().toISOString()
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true }))
})
afterEach(() => vi.unstubAllGlobals())

async function request(options: { token?: boolean; version?: string } = {}) {
  const app = Fastify()
  registerCandidateNotifications(app)
  try { return await app.inject({ method: 'POST', url: '/api/hiring/notify-assignment', headers: options.token === false ? {} : { authorization: 'Bearer token' }, payload: { applicationId: '00000000-0000-4000-8000-000000000001', version: options.version ?? state.version } }) }
  finally { await app.close() }
}

describe('candidate assignment notifications', () => {
  it('refuses unauthenticated and forced-password-change callers without sending', async () => {
    expect((await request({ token: false })).statusCode).toBe(401)
    state.identity!.mustChangePassword = true
    expect((await request()).statusCode).toBe(401)
    expect(fetch).not.toHaveBeenCalled()
  })
  it('requires review permission for sender and recipient', async () => {
    state.senderAllowed = false
    expect((await request()).statusCode).toBe(403)
    state.senderAllowed = true; state.ownerAllowed = false
    expect((await request()).json().emailSent).toBe(false)
    expect(fetch).not.toHaveBeenCalled()
  })
  it('refuses stale, old and terminal assignments', async () => {
    expect((await request({ version: 'stale' })).statusCode).toBe(409)
    state.version = '2020-01-01T00:00:00Z'
    expect((await request()).statusCode).toBe(409)
    state.version = new Date().toISOString(); state.stage = 'hired'
    expect((await request()).statusCode).toBe(409)
    expect(fetch).not.toHaveBeenCalled()
  })
  it('escapes candidate content and uses a stable deduplication key', async () => {
    expect((await request()).json().emailSent).toBe(true)
    expect((await request()).json().emailSent).toBe(true)
    const calls = vi.mocked(fetch).mock.calls
    expect(JSON.parse(String(calls[0]![1]!.body)).html).toContain('&lt;Candidate&gt;')
    expect(JSON.parse(String(calls[0]![1]!.body)).to).toEqual(['owner@example.test'])
    expect(calls[0]![1]!.headers).toEqual(calls[1]![1]!.headers)
  })
  it('reports provider failure without claiming the saved assignment failed', async () => {
    vi.mocked(fetch).mockRejectedValue(new Error('offline'))
    const response = await request()
    expect(response.statusCode).toBe(200)
    expect(response.json().emailSent).toBe(false)
    expect(response.json().message).toContain('Assignment saved')
  })
})
