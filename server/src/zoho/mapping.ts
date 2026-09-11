import type { ZohoProject, ZohoProjectMember } from './client.js'

/**
 * Pure mapping logic for the Zoho Projects sync — no I/O, fully unit-tested.
 * This is the company-mapping design from plan 015: each company's
 * `integrations` row for `zoho_projects` carries `config: { project_ids,
 * name_prefix }`. A project matches a company by explicit id, or by name
 * prefix; anything else is a routing exception, never a guess.
 */

export type CompanyMapping = {
  companyId: string
  projectIds: string[]
  namePrefix: string | null
}

/** Tolerates missing/garbage config: unreadable shapes become "no rule", never a crash. */
export function parseCompanyMapping(row: { company_id: string; config: unknown }): CompanyMapping {
  let projectIds: string[] = []
  let namePrefix: string | null = null

  const config = row.config
  if (config && typeof config === 'object' && !Array.isArray(config)) {
    const obj = config as Record<string, unknown>
    if (Array.isArray(obj.project_ids)) {
      projectIds = obj.project_ids
        .filter((value) => typeof value === 'string' || typeof value === 'number')
        .map((value) => String(value))
    }
    if (typeof obj.name_prefix === 'string' && obj.name_prefix.length > 0) {
      namePrefix = obj.name_prefix
    }
  }

  return { companyId: row.company_id, projectIds, namePrefix }
}

/**
 * An explicit id match always wins over a prefix match. When two (or more)
 * mappings match the same project only by prefix, the match is ambiguous —
 * return null rather than guess; the project surfaces as a routing exception.
 */
export function resolveCompany(project: { id: string; name: string }, mappings: CompanyMapping[]): string | null {
  const idMatch = mappings.find((mapping) => mapping.projectIds.includes(project.id))
  if (idMatch) return idMatch.companyId

  const prefixMatches = mappings.filter(
    (mapping) => mapping.namePrefix !== null && project.name.startsWith(mapping.namePrefix),
  )
  if (prefixMatches.length === 1) return prefixMatches[0].companyId

  return null
}

/** Produces exactly the `external_projects` columns the sync upserts. */
export function toProjectRow(
  project: ZohoProject,
  companyId: string,
  now: string,
): {
  provider_key: 'zoho_projects'
  external_id: string
  company_id: string
  name: string
  status: string | null
  url: string | null
  raw: unknown
  last_synced_at: string
} {
  return {
    provider_key: 'zoho_projects',
    external_id: project.id,
    company_id: companyId,
    name: project.name,
    status: project.status ?? null,
    url: project.url ?? null,
    raw: project.raw ?? {},
    last_synced_at: now,
  }
}

export type MatchedMember = { personId: string; externalRef: string | null; role: string | null }

/**
 * Emails compare case-insensitively and trimmed. Members without an email
 * can never be matched or reported (there is no email to report) — they are
 * simply absent from both `matched` and `unmatchedEmails`.
 */
export function matchMembers(
  members: ZohoProjectMember[],
  peopleByEmail: Map<string, string>,
): { matched: MatchedMember[]; unmatchedEmails: string[] } {
  const matched: MatchedMember[] = []
  const unmatchedEmails: string[] = []

  for (const member of members) {
    const normalizedEmail = member.email?.trim().toLowerCase()
    if (!normalizedEmail) continue

    const personId = peopleByEmail.get(normalizedEmail)
    if (personId) {
      matched.push({
        personId,
        externalRef: member.externalRef ?? null,
        role: member.role ?? null,
      })
    } else {
      unmatchedEmails.push(normalizedEmail)
    }
  }

  return { matched, unmatchedEmails }
}
