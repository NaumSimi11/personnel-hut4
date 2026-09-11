import type { SupabaseClient } from '@supabase/supabase-js'
import type { ZohoClient } from './client.js'
import { matchMembers, parseCompanyMapping, resolveCompany, toProjectRow, type CompanyMapping } from './mapping.js'

/**
 * Orchestration for the Zoho Projects sync. The external system owns the
 * facts; this is the only writer of the mirror tables (`external_projects`,
 * `external_project_members`) and it never edits anything back to Zoho.
 * `db` is injected so tests can run this against a real database (via
 * `serviceDb()`) or a fake, and `client` is injected so tests can run this
 * against a fixture instead of live Zoho credentials (see sync.test.ts).
 */

export type SyncResult = {
  projectsSeen: number
  projectsSynced: number
  membersSynced: number
  unmatchedProjects: { id: string; name: string }[]
  unmatchedMemberEmails: string[]
  companies: number
  dryRun: boolean
}

type IntegrationRow = { id: string; company_id: string; config: unknown }

function emptyResult(dryRun: boolean): SyncResult {
  return {
    projectsSeen: 0,
    projectsSynced: 0,
    membersSynced: 0,
    unmatchedProjects: [],
    unmatchedMemberEmails: [],
    companies: 0,
    dryRun,
  }
}

async function loadCompanyMappings(db: SupabaseClient): Promise<{ mappings: CompanyMapping[]; integrationIdByCompany: Map<string, string> }> {
  const { data, error } = await db
    .from('integrations')
    .select('id, company_id, config')
    .eq('provider_key', 'zoho_projects')
  if (error) throw new Error(`Failed to load zoho_projects integrations: ${error.message}`)

  const rows = (data ?? []) as IntegrationRow[]
  const mappings = rows.map((row) => parseCompanyMapping({ company_id: row.company_id, config: row.config }))
  const integrationIdByCompany = new Map(rows.map((row) => [row.company_id, row.id]))
  return { mappings, integrationIdByCompany }
}

async function loadPeopleByEmail(db: SupabaseClient): Promise<Map<string, string>> {
  const { data, error } = await db.from('people').select('id, work_email')
  if (error) throw new Error(`Failed to load people: ${error.message}`)

  const peopleByEmail = new Map<string, string>()
  for (const person of (data ?? []) as { id: string; work_email: string | null }[]) {
    if (person.work_email) peopleByEmail.set(person.work_email.trim().toLowerCase(), person.id)
  }
  return peopleByEmail
}

/** Marks every configured company's integration row connected/failed. Never writes in dryRun. */
async function markIntegrations(
  db: SupabaseClient,
  mappings: CompanyMapping[],
  integrationIdByCompany: Map<string, string>,
  outcome: { status: 'connected'; lastSyncAt: string } | { status: 'sync_issue'; lastError: string },
): Promise<void> {
  for (const mapping of mappings) {
    const integrationId = integrationIdByCompany.get(mapping.companyId)
    if (!integrationId) continue
    const update =
      outcome.status === 'connected'
        ? { status: 'connected', last_sync_at: outcome.lastSyncAt, last_error: null }
        : { status: 'sync_issue', last_error: outcome.lastError }
    const { error } = await db.from('integrations').update(update).eq('id', integrationId)
    if (error) throw new Error(`Failed to update integration status: ${error.message}`)
  }
}

async function upsertProject(
  db: SupabaseClient,
  row: ReturnType<typeof toProjectRow>,
): Promise<string> {
  const { data, error } = await db
    .from('external_projects')
    .upsert(row, { onConflict: 'provider_key,external_id' })
    .select('id')
    .single()
  if (error) throw new Error(`Failed to upsert project ${row.external_id}: ${error.message}`)
  return (data as { id: string }).id
}

async function syncProjectMembers(
  db: SupabaseClient,
  client: ZohoClient,
  projectExternalId: string,
  projectRowId: string,
  now: string,
  peopleByEmail: Map<string, string>,
): Promise<{ membersSynced: number; unmatchedEmails: string[] }> {
  const members = await client.listProjectMembers(projectExternalId)
  const { matched, unmatchedEmails } = matchMembers(members, peopleByEmail)

  if (matched.length > 0) {
    const memberRows = matched.map((member) => ({
      project_id: projectRowId,
      person_id: member.personId,
      external_ref: member.externalRef,
      role: member.role,
      last_synced_at: now,
    }))
    const { error } = await db
      .from('external_project_members')
      .upsert(memberRows, { onConflict: 'project_id,person_id' })
    if (error) throw new Error(`Failed to upsert members for project ${projectExternalId}: ${error.message}`)
  }

  // The mirror must not keep departed members: prune rows for people no
  // longer among the matched members of this project.
  const currentPersonIds = matched.map((member) => member.personId)
  let deleteQuery = db.from('external_project_members').delete().eq('project_id', projectRowId)
  if (currentPersonIds.length > 0) {
    deleteQuery = deleteQuery.not('person_id', 'in', `(${currentPersonIds.join(',')})`)
  }
  const { error: deleteError } = await deleteQuery
  if (deleteError)
    throw new Error(`Failed to prune departed members for project ${projectExternalId}: ${deleteError.message}`)

  return { membersSynced: matched.length, unmatchedEmails }
}

export async function syncZohoProjects(opts: {
  client: ZohoClient
  db: SupabaseClient
  dryRun?: boolean
}): Promise<SyncResult> {
  const { client, db } = opts
  const dryRun = opts.dryRun ?? false

  const { mappings, integrationIdByCompany } = await loadCompanyMappings(db)
  if (mappings.length === 0) {
    console.warn('[zoho] no company is configured for zoho_projects sync — nothing to do')
    return emptyResult(dryRun)
  }

  const peopleByEmail = await loadPeopleByEmail(db)
  const now = new Date().toISOString()

  const result = emptyResult(dryRun)
  result.companies = mappings.length

  try {
    const projects = await client.listProjects()
    result.projectsSeen = projects.length

    for (const project of projects) {
      const companyId = resolveCompany(project, mappings)
      if (!companyId) {
        result.unmatchedProjects.push({ id: project.id, name: project.name })
        continue
      }

      if (dryRun) {
        result.projectsSynced++
        continue
      }

      const row = toProjectRow(project, companyId, now)
      const projectRowId = await upsertProject(db, row)
      result.projectsSynced++

      const { membersSynced, unmatchedEmails } = await syncProjectMembers(
        db,
        client,
        project.id,
        projectRowId,
        now,
        peopleByEmail,
      )
      result.membersSynced += membersSynced
      result.unmatchedMemberEmails.push(...unmatchedEmails)
    }

    if (!dryRun) {
      await markIntegrations(db, mappings, integrationIdByCompany, { status: 'connected', lastSyncAt: now })
    }

    return result
  } catch (error) {
    if (!dryRun) {
      const message = error instanceof Error ? error.message : 'Unknown Zoho sync error'
      await markIntegrations(db, mappings, integrationIdByCompany, { status: 'sync_issue', lastError: message })
    }
    throw error
  }
}
