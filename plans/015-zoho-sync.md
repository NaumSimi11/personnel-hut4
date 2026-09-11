# Plan 015: Zoho Projects sync (read-only mirror)

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P2 / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-014)
- **Category**: integration (development-plan item — Zoho Projects sync)

## Why this matters

The app already renders project assignments read-only (company profile
Projects tab, My workspace "My projects"), but `external_projects` and
`external_project_members` are empty because nothing fills them. The docs fix
the contract: the external system owns the facts, the portal mirrors them with
source and freshness and never edits them (`docs/hr-product-plan.md` §12 for
the leave system, applied here identically), and unmatched records must
surface as exceptions rather than being guessed into the wrong company
(`docs/hr-system-blueprint.md` §5).

**Credentials are not available in this environment.** Build the job so every
part except the live HTTP calls is proven now: the Zoho client sits behind a
small interface, the mapping logic is pure and unit-tested, and an end-to-end
test runs the real sync against the real database with a fixture client.
Switching to live data must then be a matter of setting env vars only.

## Current state (all committed on main — read in your worktree)

- `server/` is a Fastify service (`src/index.ts`, `src/routes.ts`) plus
  helpers: `src/env.ts` (`env(name)` / `requiredEnv(name)`, reads repo-root
  `.env.local` with process.env taking precedence), `src/supabaseAdmin.ts`
  (`serviceDb()` returns an RLS-bypassing Supabase client), `src/account.ts`
  (pure logic + `src/account.test.ts` with Vitest — model new tests on it).
  Scripts: `npm test`, `npm run typecheck`, `npm run dev`.
- Tables (exact columns):
  - `external_projects`: id, provider_key (FK `providers.key`), external_id,
    company_id, name, status, url, raw jsonb, last_synced_at.
    **Unique (provider_key, external_id)** — that is your upsert conflict key.
  - `external_project_members`: id, project_id, person_id, external_ref, role,
    last_synced_at. **Unique (project_id, person_id)**.
  - `integrations`: id, company_id, provider_key, external_org_id,
    authorized_by, status ('not_connected'|'authorization_required'|
    'connected'|'sync_issue'|'disconnected'), last_sync_at, last_error,
    config jsonb. **Unique (company_id, provider_key)**.
  - `providers`: key, label, kind — `zoho_projects` is seeded.
  - `people`: id, full_name, work_email (citext).
  - `companies`: id, name, short_code, kind.
- RLS does not apply to `serviceDb()` (service role bypasses it) — the sync is
  the only writer of the mirror tables, exactly as designed.

**Company mapping** (the design decision this plan implements): each company's
`integrations` row for `zoho_projects` carries the mapping in `config`:

```json
{ "project_ids": ["123", "456"], "name_prefix": "SNW-" }
```

A Zoho project belongs to a company when its id is listed in `project_ids`
OR (when `name_prefix` is set) its name starts with that prefix. Projects
matching neither are **routing exceptions**: never guessed into a company,
counted and logged, and reflected in the affected integrations' `last_error`.

## Step 0: worktree env

FIRST git action: `git checkout -b feature/015-zoho-sync main`.
Then `cp /Users/naum/Downloads/files/.env.local ./.env.local` (worktree root;
gitignored — **never print that file or any of its values**, not even
filtered; it contains a database URL with an embedded password. Read values
programmatically via `process.env` inside a script). Then
`cd server && npm install`.

## Scope

**In scope**:
- `server/src/zoho/client.ts` (create)
- `server/src/zoho/mapping.ts` (create)
- `server/src/zoho/mapping.test.ts` (create)
- `server/src/zoho/sync.ts` (create)
- `server/src/zoho/sync.test.ts` (create — runs against the live DB with a
  fixture client; see Step 5)
- `server/src/zoho/run.ts` (create — the CLI entry point)
- `server/package.json` (add ONE script: `"sync:zoho": "tsx src/zoho/run.ts"`)
- `docs/integrations-zoho.md` (create)

**Out of scope**: `app/`, `supabase/` (no migrations — the tables exist),
`shared/`, `server/src/routes.ts`, `server/src/index.ts`, `plans/`, `.env*`,
every other doc.

## Git workflow

Branch `feature/015-zoho-sync` from main; conventional commits; no push/merge;
don't touch plans/README.md.

## Steps

### Step 1: `client.ts` — the Zoho boundary

Define and export:

```ts
export type ZohoProject = { id: string; name: string; status?: string; url?: string; raw: unknown }
export type ZohoProjectMember = { email: string | null; name?: string; role?: string; externalRef?: string }
export interface ZohoClient {
  listProjects(): Promise<ZohoProject[]>
  listProjectMembers(projectId: string): Promise<ZohoProjectMember[]>
}
```

Implement `createZohoClient(): Promise<ZohoClient>` using the documented
Zoho Projects REST API v3 and OAuth refresh-token flow:

- config from env (`env()` from `../env.js`): `ZOHO_CLIENT_ID`,
  `ZOHO_CLIENT_SECRET`, `ZOHO_REFRESH_TOKEN` (all required — throw a clear
  error naming the missing variable), `ZOHO_ACCOUNTS_HOST`
  (default `https://accounts.zoho.eu`), `ZOHO_API_HOST`
  (default `https://projectsapi.zoho.eu`), `ZOHO_PORTAL_ID` (optional).
- access token: `POST {accountsHost}/oauth/v2/token?refresh_token=…&client_id=…&client_secret=…&grant_type=refresh_token`
  → `access_token`; cache it in module scope for the process lifetime.
- portal: when `ZOHO_PORTAL_ID` is unset, `GET {apiHost}/api/v3/portals` and
  take the first portal's `id`.
- projects: `GET {apiHost}/api/v3/portal/{portalId}/projects`
- members: `GET {apiHost}/api/v3/portal/{portalId}/projects/{projectId}/users`
- every request sends `Authorization: Zoho-oauthtoken <token>`; non-2xx →
  throw an Error including status and a short body excerpt (never the token).

**Response parsing must be defensive** — these shapes cannot be verified in
this environment: read arrays from the first array-valued property of the
payload when the documented key is absent, coerce ids to strings, and skip
entries without an id (count them). Never let an unexpected shape crash the
job; log a warning with the count instead.

### Step 2: `mapping.ts` — pure logic (no I/O)

Export and unit-test:

```ts
export type CompanyMapping = { companyId: string; projectIds: string[]; namePrefix: string | null }
export function parseCompanyMapping(row: { company_id: string; config: unknown }): CompanyMapping
export function resolveCompany(project: { id: string; name: string }, mappings: CompanyMapping[]): string | null
export function toProjectRow(project: ZohoProject, companyId: string, now: string): {...}
export function matchMembers(members: ZohoProjectMember[], peopleByEmail: Map<string, string>): {
  matched: { personId: string; externalRef: string | null; role: string | null }[]
  unmatchedEmails: string[]
}
```

Rules: `parseCompanyMapping` tolerates missing/garbage config (→ empty
project ids, null prefix). `resolveCompany` prefers an explicit id match over
a prefix match; when two mappings both match by prefix, return `null`
(ambiguous is an exception, never a guess). Emails compare case-insensitively
and trimmed; members without an email are unmatched. `toProjectRow` produces
exactly the `external_projects` columns (provider_key `'zoho_projects'`,
external_id, company_id, name, status, url, raw, last_synced_at).

### Step 3: `sync.ts` — orchestration

```ts
export type SyncResult = {
  projectsSeen: number; projectsSynced: number; membersSynced: number
  unmatchedProjects: { id: string; name: string }[]
  unmatchedMemberEmails: string[]
  companies: number
  dryRun: boolean
}
export async function syncZohoProjects(opts: {
  client: ZohoClient
  db: SupabaseClient            // injected so tests can use serviceDb() or a fake
  dryRun?: boolean
}): Promise<SyncResult>
```

Steps inside: load `integrations` where `provider_key = 'zoho_projects'` →
mappings (when none exist, return a result with `companies: 0` and log that
no company is configured — not an error); load `people` (id, work_email) into
a lowercase email→id Map; `client.listProjects()`; resolve each project's
company; for matched projects (unless `dryRun`) upsert into
`external_projects` on conflict `(provider_key, external_id)`, then
`client.listProjectMembers(project.id)` and upsert matched members on conflict
`(project_id, person_id)`; **delete member rows for that project whose
person_id is no longer present** (the mirror must not keep departed members).
Finally, per configured company, update its `integrations` row:
`status: 'connected'`, `last_sync_at: now`, `last_error: null` on success; on
a thrown error `status: 'sync_issue'` and `last_error` = the message (never
include tokens), then rethrow. In `dryRun`, perform NO writes at all.

### Step 4: `run.ts` — CLI

Parse `--dry-run` from `process.argv`; build the client with
`createZohoClient()`; call `syncZohoProjects({ client, db: serviceDb(), dryRun })`;
print a human summary (projects seen/synced, members synced, unmatched counts,
first few unmatched project names); `process.exit(1)` on a thrown error after
printing the message. No secrets in any output.

### Step 5: Tests

`mapping.test.ts` (pure, fast) — at minimum: id match wins over prefix;
prefix match works; no match → null; ambiguous prefix → null; garbage config
tolerated; member emails matched case-insensitively; members without email
reported unmatched.

`sync.test.ts` (real database, fixture client) — uses `serviceDb()` and a
hand-written `ZohoClient` fixture returning two projects (one mapped to
Snowball by id, one unmappable) and two members (one matching a seeded
person's work email, one unknown). The test must:
1. Look up Snowball (`short_code = 'SNOW'`); seed a person
   `E2E Zoho Member` with work_email `e2e-zoho-member@synami.com`; upsert an
   `integrations` row for (Snowball, zoho_projects) with
   `config: { project_ids: ['ZP-1'] }`.
2. Run with `dryRun: true` → assert NO rows were written and the result
   counts the mapped project.
3. Run for real → assert one `external_projects` row exists for
   `(zoho_projects, 'ZP-1')` with company Snowball, one
   `external_project_members` row linking the seeded person, the result lists
   the unmapped project in `unmatchedProjects` and the unknown email in
   `unmatchedMemberEmails`, and the `integrations` row is now
   `status = 'connected'` with a `last_sync_at`.
4. Run again (idempotency) → still exactly one project row and one member row.
5. Clean up EVERYTHING it created, in order: `external_project_members` →
   `external_projects` → `people` → the `integrations` row (delete it; it did
   not exist before), both in `beforeAll` and `afterAll`.

Keep Vitest's default environment; no Playwright involved.

**Verify**: `cd server && npm test` → all pass (existing 8 + your new ones);
`npm run typecheck` → exit 0.

### Step 6: `docs/integrations-zoho.md`

Short and operational: what the sync does (read-only mirror), the env vars
with their defaults (list names only — **never example real secrets**), how
to obtain a refresh token (Zoho API console: self-client → scope
`ZohoProjects.projects.READ,ZohoProjects.users.READ` → exchange the code),
how company mapping works (`integrations.config` with `project_ids` /
`name_prefix`, and that unmatched projects are reported, never guessed), how
to run (`npm run sync:zoho -- --dry-run` first, then without the flag), and
what the app shows afterwards (company profile Projects tab, My workspace).
Note that scheduling (cron/pg_cron) is deliberately out of scope for now.

## Done criteria

- [ ] `cd server && npm test` green (existing + new), `npm run typecheck` exit 0
- [ ] `npm run sync:zoho -- --dry-run` fails with a clear "ZOHO_CLIENT_ID is
      not configured"-style message (credentials are absent here) — capture
      that output in your report as proof the CLI wires up
- [ ] `git diff --stat main` → only the 8 in-scope files
- [ ] Committed on `feature/015-zoho-sync`

## STOP conditions

- A mirror table's columns differ from this plan (drift).
- The live-DB sync test cannot clean up after itself (report what remains).
- Anything needs an out-of-scope file (especially: do NOT add a migration).

## Report format

```
STATUS: COMPLETE | STOPPED
STEPS: per step — done/skipped + verification result
STOPPED BECAUSE: (only if STOPPED)
FILES CHANGED: list
NOTES: deviations/surprises + worktree path + branch + final commit SHA
```
