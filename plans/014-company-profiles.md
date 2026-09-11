# Plan 014: Company profiles — the holding and its companies

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P2 / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-013)
- **Category**: feature (development-plan item 2 — company profiles)

## Why this matters

The holding structure is this product's differentiator: four companies under
Hut4, each with its own people, access grants, hiring and connections
(`docs/hr-system-blueprint.md` §2). Today the app shows those things only
company-agnostically, so a director has no "my company at a glance" view. The
prototype's company profile (Overview / People / Access / Hiring /
Integrations tabs) is the design; this plan implements it against live data,
adding a Projects tab for the read-only external mirror.

## Current state (all committed on main — read in your worktree)

Tables and columns (exact — from `supabase/migrations/`):

- `companies`: id, parent_company_id, kind ('holding'|'company'), name,
  short_code, brand jsonb, settings jsonb, archived_at.
  Seeded: Hut4 (holding) + Praedium, Synami, Snowball, "Fourth company
  (rename me)".
- `employment_periods`: person_id, company_id, job_title, status, start_date,
  end_date, employment_type_key.
- `access_grants`: id, person_id, company_id + `grant_capabilities(capability_key)`.
- `hiring_requests`: id, company_id, title, status, headcount,
  target_start_date.
- `jobs`: id, company_id, title, status, hiring_request_id.
- `plans`: id, company_id, kind, status, start_date, person_id.
- `external_projects`: id, provider_key, external_id, company_id, name,
  status, url, last_synced_at (NOTE: **provider_key**, there is no `source`
  column).
- `external_project_members`: id, project_id, person_id, role, last_synced_at.
- `integrations`: id, company_id, provider_key, external_org_id, status
  ('not_connected'|'authorization_required'|'connected'|'sync_issue'|
  'disconnected'), last_sync_at, last_error.
- `providers`: key, label, kind ('projects'|'leave'|'recruitment'|
  'publishing'), archived_at. Seeded: zoho_projects, leave_system,
  linkedin_recruitment, linkedin_pages, indeed.

**FK hints** — verify every one against the Relationships arrays in
`app/src/types/database.ts`, never guess. Expect
`employment_periods_person_id_fkey`, `access_grants_person_id_fkey`,
`external_project_members_project_id_fkey`,
`external_project_members_person_id_fkey`, `integrations_provider_key_fkey`.

Conventions: model pages on `app/src/pages/PersonProfilePage.vue` (header +
cards) and `OnboardingPage.vue` (row lists); tokens in
`app/src/styles/main.css` (`.card`, `.card-head`, `.badge`, `.empty`,
`.error-note`, `.person-cell`, `.avatar`, `.table-wrap`); counts via
`{ count: 'exact', head: true }`; `auth` store exposes `isAdmin`, `personId`.
E2E: model on `app/e2e/home.spec.ts` (service-client seeding + cleanup).

## Step 0: worktree env

FIRST git action: `git checkout -b feature/014-company-profiles main`.
Then `cp /Users/naum/Downloads/files/.env.local ./.env.local` (worktree root;
gitignored — **never print that file or any of its values**, not even
filtered; it contains a database URL with an embedded password. Read values
programmatically via `process.env` inside a script instead). Then
`cd app && npm install && npx playwright install chromium`. E2E vite port 5199
must be free; the auth service on 8787 may already run (fine — out of scope).

## Scope

**In scope**:
- `app/src/pages/CompaniesPage.vue` (create — the holding list)
- `app/src/pages/CompanyProfilePage.vue` (create — one company, tabbed)
- `app/src/router/index.ts` (ADD two routes only)
- `app/src/components/AppShell.vue` (add one nav link, second — right after
  Overview)
- `app/e2e/companies.spec.ts` (create)

**Out of scope**: every other page/component/spec, `server/`, `supabase/`,
`shared/`, stores, `prototype/`, `plans/`, `docs/`, `.env*`. Do not change any
existing route, redirect or guard.

## Git workflow

Branch `feature/014-company-profiles` from main; conventional commits; no
push/merge; don't touch plans/README.md.

## Steps

### Step 1: Routes + nav

Routes (children of AppShell):
`{ path: 'companies', name: 'companies', component: () => import('@/pages/CompaniesPage.vue') }`
`{ path: 'companies/:companyId', name: 'company', component: () => import('@/pages/CompanyProfilePage.vue') }`
AppShell nav: `<router-link :to="{ name: 'companies' }">Companies</router-link>`
immediately after the Overview link.

### Step 2: CompaniesPage.vue

Header: eyebrow 'The holding', h1 'Four companies. One workspace.', sub-line
'Select a company to review its people, access and hiring activity.'

Load `companies` where `archived_at is null`, ordered by `kind desc, name`
(so the holding sorts first). Render the holding row (kind = 'holding') as a
banner-style card noting 'Parent organization'. Render each company
(kind = 'company') as a card in a responsive grid: short_code badge/tile,
name, headcount (count of `employment_periods` for that company with
`end_date is null`), and an 'Open company profile →' router-link to
`{ name: 'company', params: { companyId } }`.

Headcounts: one query is enough — select `company_id` from
`employment_periods` where `end_date is null`, then count client-side per
company (do NOT issue one query per company).

Empty/error states as elsewhere (`.empty`, single `.error-note`).

### Step 3: CompanyProfilePage.vue — shell, header, tabs

Load the company by `route.params.companyId`; if missing/not visible show
`.error-note` 'Company not found or not visible with your access.'

Header: eyebrow 'Holding / company profile', the short_code tile, h1 company
name, meta line `Part of Hut4 · <headcount> people`, and a back link to
Companies.

Tabs: Overview, People, Access, Hiring, Projects, Integrations. Drive the
active tab from the query string (`?tab=people`) with `overview` as default,
so tabs are deep-linkable: clicking a tab does
`router.replace({ query: { tab } })` and a `computed` reads
`route.query.tab`. Render tab buttons with an `.active` class (add
component-scoped styles modeled on the prototype's `.tabs`/`.tab`).

Load all tab data in ONE `Promise.all` on mount (the datasets are small);
a failure shows a single `.error-note` 'Could not load this company.' plus
`console.error` detail.

### Step 4: The six tabs

1. **Overview** — four metric tiles: People (active employments), Hiring
   requests (count where status = 'submitted'), Onboarding (plans where
   kind='onboarding' and status='in_progress'), Connected channels
   (integrations where status='connected'). Below them a 'Company details'
   card: parent organization ('Hut4' when `parent_company_id` is set, else
   '—'), short code, employment structure ('One employing company per
   person'), HR workspace ('Shared across the holding').
2. **People** — table of current employments for this company:
   `employment_periods` where `company_id` and `end_date is null`, select
   `id, job_title, status, start_date, person:people!employment_periods_person_id_fkey(id, full_name, work_email)`.
   Columns: person (avatar + name + email, linking to
   `{ name: 'person', params: { personId } }`), role, status badge, start
   date. Empty: 'Nobody is employed here yet.'
3. **Access** — `access_grants` where `company_id`, select
   `id, person:people!access_grants_person_id_fkey(id, full_name),
   grant_capabilities(capability_key)`. Rows: person name, `${n}
   capabilities`, and an 'Edit' router-link to
   `{ name: 'access-editor', params: { personId }, query: { company: companyId } }`.
   Empty: 'No grants in this company yet.'
4. **Hiring** — two lists: `hiring_requests` for this company (title, status
   badge: submitted=amber, approved=green, rejected/cancelled=gray,
   changes_requested=blue) and `jobs` for this company (title, status badge,
   'Open job' link to `{ name: 'job', params: { jobId } }`). Empty states for
   each.
5. **Projects** — `external_projects` where `company_id`, select
   `id, name, status, provider_key, last_synced_at` plus member names via
   `external_project_members!external_project_members_project_id_fkey(person:people!external_project_members_person_id_fkey(full_name))`
   (verify both hints; if the nested embed is awkward, fetch members in a
   second query keyed by project id — either is fine). Row: project name,
   status badge, `${provider_key} · last sync <localized date>`, member names.
   Below the list an `.error-note`-free note styled like the app's other
   inline notes: 'Project facts stay in the external system. This panel is
   read-only.' Empty: 'No projects synced for this company.'
6. **Integrations** — left join in spirit: load `providers` (all, not
   archived) and `integrations` for this company; render one row per provider
   with its label, kind, and the matching integration's status badge
   (connected=green, sync_issue/authorization_required=amber, else gray) —
   when no integration row exists show 'Not connected' (gray). Include a note:
   'No credentials are collected here; connections are configured per company
   and confirmed by the provider.'

**Verify**: `cd app && npm run build` → exit 0.

### Step 5: E2E `app/e2e/companies.spec.ts`

Seed with the service client against **Snowball** (`short_code = 'SNOW'`).
Constants: person `E2E Co Employee`, request `E2E Co Request`, project
`E2E Co Project` (external_id `E2E-CO-1`, provider_key `zoho_projects`).

Cleanup before and after, in this order: `external_project_members` (by
project id) → `external_projects` (by external_id) → `employment_periods`
(by person id) → `people` (by full_name) → `hiring_requests` (by title).

Seed: person → employment_period (Snowball, job_title 'Co Tester', status
'active', start_date today) → hiring_request (Snowball, title
'E2E Co Request', status 'submitted') → external_project (Snowball,
name 'E2E Co Project', status 'Active', provider_key 'zoho_projects',
external_id 'E2E-CO-1') → external_project_member linking the seeded person.

Test (one sequential flow):
1. Admin signs in → click the **Companies** nav link (`exact: true`).
2. The Snowball card is visible; click its 'Open company profile →'.
3. Overview: h1 is 'Snowball'; the four metric tiles render (assert the
   People tile shows a digit string — do not assert exact totals).
4. **People** tab → row `E2E Co Employee` with role `Co Tester`.
5. **Access** tab → renders (rows or the empty state — assert the tab panel
   is visible, e.g. by its heading/empty text).
6. **Hiring** tab → `E2E Co Request` visible with an `submitted` badge.
7. **Projects** tab → `E2E Co Project` visible and the read-only note.
8. **Integrations** tab → at least one provider label from the seeded set
   (e.g. 'Zoho Projects') with a status badge.
9. Reload the page with `?tab=hiring` in the URL → the Hiring tab is active
   (deep-linking works).

**Verify**: `npx playwright test e2e/companies.spec.ts` → 1 passed.

### Step 6: gates

`cd app && npm test` (unit) and `npm run build` — green. Run ONLY your spec.

## Done criteria

- [ ] build + unit green; `npx playwright test e2e/companies.spec.ts` → 1 passed
- [ ] `git diff --stat main` → only the 5 in-scope files
- [ ] `git diff main -- app/src/router/index.ts` shows only two added routes
- [ ] Committed on `feature/014-company-profiles`

## STOP conditions

- An FK-hinted embed cannot be resolved from the generated types (report the
  Relationships entries you found).
- A seeded row is invisible to the admin in the UI (report the query + what
  RLS returned).
- E2E fails twice on live-data state rather than your code.
- Anything needs an out-of-scope file.

## Report format

```
STATUS: COMPLETE | STOPPED
STEPS: per step — done/skipped + verification result
STOPPED BECAUSE: (only if STOPPED)
FILES CHANGED: list
NOTES: deviations/surprises + worktree path + branch + final commit SHA
```
