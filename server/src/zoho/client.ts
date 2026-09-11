import { env, requiredEnv } from '../env.js'

/**
 * The Zoho Projects boundary. Everything above this file works against the
 * `ZohoClient` interface, never against the HTTP API directly — that is what
 * lets `sync.ts` be tested end-to-end with a fixture client while real Zoho
 * credentials are unavailable in this environment.
 */

export type ZohoProject = {
  id: string
  name: string
  status?: string
  url?: string
  raw: unknown
}

export type ZohoProjectMember = {
  email: string | null
  name?: string
  role?: string
  externalRef?: string
}

export interface ZohoClient {
  listProjects(): Promise<ZohoProject[]>
  listProjectMembers(projectId: string): Promise<ZohoProjectMember[]>
}

type ZohoConfig = {
  clientId: string
  clientSecret: string
  refreshToken: string
  accountsHost: string
  apiHost: string
  portalId?: string
}

function loadConfig(): ZohoConfig {
  return {
    // Required first so a missing credential fails fast with a clear,
    // secret-free message (this is what `npm run sync:zoho` proves in an
    // environment with no Zoho credentials configured).
    clientId: requiredEnv('ZOHO_CLIENT_ID'),
    clientSecret: requiredEnv('ZOHO_CLIENT_SECRET'),
    refreshToken: requiredEnv('ZOHO_REFRESH_TOKEN'),
    accountsHost: env('ZOHO_ACCOUNTS_HOST') ?? 'https://accounts.zoho.eu',
    apiHost: env('ZOHO_API_HOST') ?? 'https://projectsapi.zoho.eu',
    portalId: env('ZOHO_PORTAL_ID'),
  }
}

// Cached for the process lifetime — one refresh per run, never logged.
let cachedAccessToken: string | null = null

async function fetchAccessToken(config: ZohoConfig): Promise<string> {
  if (cachedAccessToken) return cachedAccessToken
  const url = new URL('/oauth/v2/token', config.accountsHost)
  url.searchParams.set('refresh_token', config.refreshToken)
  url.searchParams.set('client_id', config.clientId)
  url.searchParams.set('client_secret', config.clientSecret)
  url.searchParams.set('grant_type', 'refresh_token')

  const res = await fetch(url, { method: 'POST' })
  if (!res.ok) throw await requestError('access token refresh', res)

  const body = (await res.json()) as { access_token?: unknown }
  if (typeof body.access_token !== 'string' || body.access_token.length === 0) {
    throw new Error('Zoho access token refresh: response had no access_token')
  }
  cachedAccessToken = body.access_token
  return cachedAccessToken
}

/** Never includes the token or request body — only status, method, and a short response excerpt. */
async function requestError(label: string, res: Response): Promise<Error> {
  let excerpt = ''
  try {
    excerpt = (await res.text()).slice(0, 200)
  } catch {
    excerpt = '(no body)'
  }
  return new Error(`Zoho ${label} failed: ${res.status} ${res.statusText} — ${excerpt}`)
}

async function authorizedGet(config: ZohoConfig, path: string): Promise<unknown> {
  const token = await fetchAccessToken(config)
  const url = new URL(path, config.apiHost)
  const res = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` },
  })
  if (!res.ok) throw await requestError(path, res)
  return res.json()
}

/**
 * Zoho's documented response envelopes vary by endpoint and cannot be
 * verified in this environment. Defensive read: prefer the documented key,
 * else fall back to the first array-valued property found on the payload.
 */
function extractArray(payload: unknown, preferredKey: string): unknown[] {
  if (payload && typeof payload === 'object' && !Array.isArray(payload)) {
    const obj = payload as Record<string, unknown>
    if (Array.isArray(obj[preferredKey])) return obj[preferredKey] as unknown[]
    for (const value of Object.values(obj)) {
      if (Array.isArray(value)) return value
    }
  }
  if (Array.isArray(payload)) return payload
  return []
}

function asString(value: unknown): string | undefined {
  if (typeof value === 'string') return value
  if (typeof value === 'number') return String(value)
  return undefined
}

async function resolvePortalId(config: ZohoConfig): Promise<string> {
  if (config.portalId) return config.portalId
  const payload = await authorizedGet(config, '/api/v3/portals')
  const portals = extractArray(payload, 'portals')
  const first = portals[0] as Record<string, unknown> | undefined
  const id = asString(first?.id)
  if (!id) throw new Error('Zoho portals: no portal id found in response')
  return id
}

async function fetchProjects(config: ZohoConfig, portalId: string): Promise<ZohoProject[]> {
  const payload = await authorizedGet(config, `/api/v3/portal/${portalId}/projects`)
  const rawProjects = extractArray(payload, 'projects')

  const projects: ZohoProject[] = []
  let skipped = 0
  for (const raw of rawProjects) {
    if (!raw || typeof raw !== 'object') {
      skipped++
      continue
    }
    const obj = raw as Record<string, unknown>
    const id = asString(obj.id)
    if (!id) {
      skipped++
      continue
    }
    const statusValue = obj.status
    const status =
      typeof statusValue === 'string'
        ? statusValue
        : asString((statusValue as Record<string, unknown> | undefined)?.name)
    projects.push({
      id,
      name: asString(obj.name) ?? '',
      status,
      url: asString(obj.url),
      raw: obj,
    })
  }
  if (skipped > 0) console.warn(`[zoho] skipped ${skipped} project entr${skipped === 1 ? 'y' : 'ies'} with no id`)
  return projects
}

async function fetchProjectMembers(
  config: ZohoConfig,
  portalId: string,
  projectId: string,
): Promise<ZohoProjectMember[]> {
  const payload = await authorizedGet(config, `/api/v3/portal/${portalId}/projects/${projectId}/users`)
  const rawUsers = extractArray(payload, 'users')

  const members: ZohoProjectMember[] = []
  let skipped = 0
  for (const raw of rawUsers) {
    if (!raw || typeof raw !== 'object') {
      skipped++
      continue
    }
    const obj = raw as Record<string, unknown>
    members.push({
      email: asString(obj.email) ?? asString(obj.email_id) ?? null,
      name: asString(obj.name),
      role: typeof obj.role === 'string' ? obj.role : asString((obj.role as Record<string, unknown> | undefined)?.name),
      externalRef: asString(obj.id),
    })
  }
  if (skipped > 0) console.warn(`[zoho] skipped ${skipped} member entr${skipped === 1 ? 'y' : 'ies'} with unreadable shape`)
  return members
}

export async function createZohoClient(): Promise<ZohoClient> {
  const config = loadConfig()
  const portalId = await resolvePortalId(config)
  return {
    listProjects: () => fetchProjects(config, portalId),
    listProjectMembers: (projectId: string) => fetchProjectMembers(config, portalId, projectId),
  }
}
