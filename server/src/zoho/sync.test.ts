import type { SupabaseClient } from '@supabase/supabase-js'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { serviceDb } from '../supabaseAdmin.js'
import type { ZohoClient, ZohoProject, ZohoProjectMember } from './client.js'
import { syncZohoProjects } from './sync.js'

/**
 * Runs the real sync against the live database (`serviceDb()`) with a
 * hand-written `ZohoClient` fixture in place of live Zoho HTTP calls, which
 * are unavailable in this environment. This is the proof that everything
 * except those HTTP calls works end-to-end: company mapping, the upsert
 * conflict keys, member pruning, idempotency, and integration status
 * updates. Seeds its own fixtures and cleans up after itself — in
 * `beforeAll` (in case a previous failed run left something behind) and in
 * `afterAll`.
 */

const TEST_EXTERNAL_ID = 'ZP-1'
const TEST_PERSON_EMAIL = 'e2e-zoho-member@synami.com'
const TEST_PERSON_NAME = 'E2E Zoho Member'

const MAPPED_PROJECT: ZohoProject = {
  id: TEST_EXTERNAL_ID,
  name: 'E2E Website Relaunch',
  status: 'Active',
  url: 'https://projects.zoho.eu/e2e-website-relaunch',
  raw: { id: TEST_EXTERNAL_ID, name: 'E2E Website Relaunch' },
}
const UNMAPPED_PROJECT: ZohoProject = {
  id: 'ZP-999-unmapped',
  name: 'E2E Unrelated Project',
  status: 'Active',
  raw: { id: 'ZP-999-unmapped' },
}
const MATCHED_MEMBER: ZohoProjectMember = {
  email: TEST_PERSON_EMAIL,
  name: TEST_PERSON_NAME,
  role: 'Developer',
  externalRef: 'zu-1',
}
const UNKNOWN_MEMBER: ZohoProjectMember = { email: 'unknown-e2e-zoho@synami.com', name: 'Unknown Person' }

function fixtureClient(): ZohoClient {
  return {
    async listProjects() {
      return [MAPPED_PROJECT, UNMAPPED_PROJECT]
    },
    async listProjectMembers(projectId: string) {
      return projectId === MAPPED_PROJECT.id ? [MATCHED_MEMBER, UNKNOWN_MEMBER] : []
    },
  }
}

async function findExternalProjectId(db: SupabaseClient): Promise<string | null> {
  const { data } = await db
    .from('external_projects')
    .select('id')
    .eq('provider_key', 'zoho_projects')
    .eq('external_id', TEST_EXTERNAL_ID)
    .maybeSingle()
  return (data as { id: string } | null)?.id ?? null
}

/** Deletes everything this suite creates, in dependency order: members -> project -> person -> integration row. */
async function cleanUp(db: SupabaseClient, snowballId: string): Promise<void> {
  const projectId = await findExternalProjectId(db)
  if (projectId) {
    await db.from('external_project_members').delete().eq('project_id', projectId)
    await db.from('external_projects').delete().eq('id', projectId)
  }
  await db.from('people').delete().eq('work_email', TEST_PERSON_EMAIL)
  await db.from('integrations').delete().eq('company_id', snowballId).eq('provider_key', 'zoho_projects')
}

describe('syncZohoProjects (live database, fixture Zoho client)', () => {
  const db = serviceDb()
  let snowballId: string
  let personId: string

  beforeAll(async () => {
    const { data: snowball, error } = await db.from('companies').select('id').eq('short_code', 'SNOW').single()
    if (error || !snowball) {
      throw new Error(`Fixture setup: Snowball (short_code=SNOW) not found: ${error?.message ?? 'no row'}`)
    }
    snowballId = (snowball as { id: string }).id

    await cleanUp(db, snowballId) // in case a previous failed run left fixtures behind

    const { data: person, error: personError } = await db
      .from('people')
      .insert({ full_name: TEST_PERSON_NAME, work_email: TEST_PERSON_EMAIL })
      .select('id')
      .single()
    if (personError || !person) {
      throw new Error(`Fixture setup: could not seed test person: ${personError?.message ?? 'no row returned'}`)
    }
    personId = (person as { id: string }).id

    const { error: integrationError } = await db.from('integrations').insert({
      company_id: snowballId,
      provider_key: 'zoho_projects',
      config: { project_ids: [TEST_EXTERNAL_ID] },
    })
    if (integrationError) {
      throw new Error(`Fixture setup: could not seed integrations row: ${integrationError.message}`)
    }
  })

  afterAll(async () => {
    await cleanUp(db, snowballId)
  })

  it('dry run performs no writes and reports the mapped project as would-sync', async () => {
    const result = await syncZohoProjects({ client: fixtureClient(), db, dryRun: true })

    expect(result.dryRun).toBe(true)
    expect(result.companies).toBe(1)
    expect(result.projectsSeen).toBe(2)
    expect(result.projectsSynced).toBe(1)
    expect(result.membersSynced).toBe(0)
    expect(result.unmatchedProjects).toEqual([{ id: UNMAPPED_PROJECT.id, name: UNMAPPED_PROJECT.name }])

    expect(await findExternalProjectId(db)).toBeNull()

    const { data: integration } = await db
      .from('integrations')
      .select('status, last_sync_at')
      .eq('company_id', snowballId)
      .eq('provider_key', 'zoho_projects')
      .single()
    expect((integration as { status: string }).status).toBe('not_connected')
    expect((integration as { last_sync_at: string | null }).last_sync_at).toBeNull()
  })

  it('syncs the mapped project and its matched member, reporting the routing exception and the unknown email', async () => {
    const result = await syncZohoProjects({ client: fixtureClient(), db, dryRun: false })

    expect(result.projectsSeen).toBe(2)
    expect(result.projectsSynced).toBe(1)
    expect(result.membersSynced).toBe(1)
    expect(result.unmatchedProjects).toEqual([{ id: UNMAPPED_PROJECT.id, name: UNMAPPED_PROJECT.name }])
    expect(result.unmatchedMemberEmails).toEqual([UNKNOWN_MEMBER.email])

    const { data: projectRow, error: projectError } = await db
      .from('external_projects')
      .select('id, company_id, name, status, url')
      .eq('provider_key', 'zoho_projects')
      .eq('external_id', TEST_EXTERNAL_ID)
      .single()
    expect(projectError).toBeNull()
    expect((projectRow as { company_id: string }).company_id).toBe(snowballId)
    expect((projectRow as { name: string }).name).toBe(MAPPED_PROJECT.name)

    const { data: memberRows, error: memberError } = await db
      .from('external_project_members')
      .select('person_id, external_ref, role')
      .eq('project_id', (projectRow as { id: string }).id)
    expect(memberError).toBeNull()
    expect(memberRows).toHaveLength(1)
    expect((memberRows as { person_id: string }[])[0].person_id).toBe(personId)

    const { data: integration } = await db
      .from('integrations')
      .select('status, last_sync_at')
      .eq('company_id', snowballId)
      .eq('provider_key', 'zoho_projects')
      .single()
    expect((integration as { status: string }).status).toBe('connected')
    expect((integration as { last_sync_at: string | null }).last_sync_at).not.toBeNull()
  })

  it('is idempotent: running again still leaves exactly one project row and one member row', async () => {
    const result = await syncZohoProjects({ client: fixtureClient(), db, dryRun: false })
    expect(result.projectsSynced).toBe(1)
    expect(result.membersSynced).toBe(1)

    const projectId = await findExternalProjectId(db)
    expect(projectId).not.toBeNull()

    const { data: projectRows } = await db
      .from('external_projects')
      .select('id')
      .eq('provider_key', 'zoho_projects')
      .eq('external_id', TEST_EXTERNAL_ID)
    expect(projectRows).toHaveLength(1)

    const { data: memberRows } = await db
      .from('external_project_members')
      .select('id')
      .eq('project_id', projectId as string)
    expect(memberRows).toHaveLength(1)
  })
})
