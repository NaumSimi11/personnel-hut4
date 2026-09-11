# Plan 013: Self-service — My workspace

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-012)
- **Category**: feature (development-plan item 2 — self-service)

## Why this matters

Every screen so far is built for HR and admins looking at *other* people.
Employee self-service is the surface an ordinary team member touches daily and
the biggest capability gap versus the products the docs benchmark against
(Personio, BambooHR, HiBob); `docs/hr-product-plan.md` §11 proposes
"employees access their own permitted information/tasks", and the prototype's
view-as overview is its design. This page answers, for the signed-in person:
what is my record, what is waiting on me, and what am I allowed to do.

Self-access is already granted by RLS (`app.is_self(...)` branches), so an
employee with **no capabilities at all** can still see their own profile,
their own onboarding plan, their own tasks, their own grants and their own
project assignments. No migration is needed.

## Current state (all committed on main — read in your worktree)

- `auth` store (`app/src/stores/auth.ts`) exposes `session`, `personId`,
  `personName`, `isAdmin`.
- Pages to model on: `app/src/pages/PersonProfilePage.vue` (profile layout,
  employment rows), `OnboardingPlanPage.vue` (task rows + status updates),
  `HomePage.vue` (queue rows, parallel loading, single error note).
- Tables/columns (already used elsewhere — copy those query shapes):
  - `people`: id, full_name, work_email, user_id.
  - `employment_periods`: person_id, company_id, job_title, status,
    start_date, end_date, employment_type_key + `company:companies(name)`.
  - `plans`: id, kind, status, start_date, person_id + `plan_tasks(...)`.
  - `plan_tasks`: id, plan_id, title, description, owner_id, owner_role,
    phase_key, due_date, critical, status, blocked_reason, skip_reason.
  - `access_grants`: person_id, company_id + `company:companies(name)` +
    `grant_capabilities(capability_key)`.
  - `capabilities`: key, label (for turning keys into human labels).
  - `external_project_members`: person_id, project_id + project embed;
    `external_projects`: id, name, status, source, last_synced_at.
- **FK hints** (verify each in the Relationships arrays of
  `app/src/types/database.ts` — never guess): `plans_person_id_fkey`,
  `plan_tasks_plan_id_fkey`, `plan_tasks_owner_id_fkey`,
  `external_project_members_project_id_fkey`.

## Step 0: worktree env

FIRST git action: `git checkout -b feature/013-my-workspace main` (worktrees
can start behind main). Then `cp /Users/naum/Downloads/files/.env.local
./.env.local` (worktree root; gitignored — **never print the file or any of
its values**, not even filtered: it contains a database URL with an embedded
password). Then `cd app && npm install && npx playwright install chromium`.
E2E vite port 5199 must be free; the auth service on 8787 may already run from
the main checkout (fine — out of scope).

## Scope

**In scope**:
- `app/src/pages/MyWorkspacePage.vue` (create)
- `app/src/router/index.ts` (ADD one route only)
- `app/src/components/AppShell.vue` (add one nav link, LAST in the list)
- `app/e2e/my-workspace.spec.ts` (create)

**Out of scope**: every other page/component/spec, `server/`, `supabase/`,
`shared/`, stores, `prototype/`, `plans/`, `docs/`, `.env*`. Do not change any
existing route, redirect or guard.

## Git workflow

Branch `feature/013-my-workspace` from main; conventional commits; no
push/merge; don't touch plans/README.md.

## Steps

### Step 1: Route + nav

Route (child of AppShell, after the existing ones):
`{ path: 'me', name: 'my-workspace', component: () => import('@/pages/MyWorkspacePage.vue') }`.
AppShell nav: `<router-link :to="{ name: 'my-workspace' }">My workspace</router-link>`
as the LAST link.

### Step 2: MyWorkspacePage.vue — shell and profile

If `auth.personId` is null, render a single `.card` with `.empty`:
'Your sign-in is not linked to an employee record yet. Ask HR to connect it.'
and skip all queries.

Header: eyebrow 'My workspace', h1 `Welcome, <first name>.` (from
`auth.personName`, fallback 'there'), sub-line 'Your record, your tasks, and
what you can do in each company.'

Two-column layout (mirror `.grid-two` usage in `PersonProfilePage.vue`).

**Right column — My profile card**: full name, work email (or '—'), and the
current employment (the `employment_periods` row for me with `end_date is
null`, newest first): job title · company, status badge, start date. Below it,
an 'Employment history' list of all my periods (title · company, dates,
status badge) — read-only, no actions.

### Step 3: Left column — my onboarding and my tasks

**My onboarding card** (only when a plan exists): my `plans` row where
`person_id = auth.personId` and `kind = 'onboarding'`, newest by start_date,
with its `plan_tasks` ordered by `sort_order`. Show start date, a readiness
badge using the same rule as elsewhere (`critical && status !== 'done' &&
status !== 'skipped'` → `${n} readiness gaps` amber, else 'Ready for day one'
green), then the task rows: title, owner_role, due date, `Required before
start` when critical, status badge (done=green, blocked=amber, skipped=gray,
open=blue). **Read-only** — an employee does not tick off HR's checklist here.

**My tasks card**: `plan_tasks` where `owner_id = auth.personId` and
`status = 'open'`, ordered by `due_date` (nulls last is fine), select
`id, title, due_date, plan_id`. Each row: title, due date, a **Mark complete**
button → update `{ status: 'done', done_by: auth.personId, done_at: new
Date().toISOString() }` then reload, plus a router-link 'Open plan' →
`{ name: 'onboarding-plan', params: { planId: plan_id } }`.
Empty state: 'No tasks assigned to you.'
On update error show `.error-note`; if the message mentions `row-level
security` or `permission`, show 'You do not have permission to change this
task.'

### Step 4: Right column — my access and my projects

**My access card**: `access_grants` where `person_id = auth.personId`, select
`company_id, company:companies(name), grant_capabilities(capability_key)`.
Load `capabilities` (`key, label`) once and map keys → labels, sorted
alphabetically. Render one block per company: company name + `${n}
capabilities`, then a `<ul>` of labels. When a company block has none, show
'No capabilities granted here.'
- When `auth.isAdmin`, ALSO show an `.inline-note`-style line above the list:
  'You are a platform admin: full access across every company.' (add a
  component-scoped style if `.inline-note` is not in `main.css`).
- When there are no grants at all and not an admin: 'No capabilities granted
  in any company yet.'

**My projects card**: `external_project_members` where
`person_id = auth.personId`, embedding the project
(`project:external_projects!external_project_members_project_id_fkey(id, name, status, source, last_synced_at)`).
Each row: project name, status badge, and small text `${source} · last sync
${new Date(last_synced_at).toLocaleString()}`. Empty state: 'No project
assignments synced.' Read-only — the external system owns these facts.

Load everything in one `Promise.all`; on any failure show a single
`.error-note` ('Could not load your workspace.') and `console.error` the
detail — never leave the page blank.

**Verify**: `cd app && npm run build` → exit 0.

### Step 5: E2E `app/e2e/my-workspace.spec.ts`

The signed-in test user is a platform admin whose person row has **no
employment period** — that is realistic for this page and must not be
"fixed" by the test. Do NOT modify the admin's own person/grant rows.

Seed (service client) a plan owned by a *separate* seeded person, with ONE
task assigned to the admin, so "My tasks" has deterministic content:
- constants: person `E2E MW Starter`, task `E2E MW Task For Admin`
- look up the admin's person id: `people` where
  `work_email = process.env.TEST_USER_EMAIL`
- seed: person → employment_period (Snowball, `short_code = 'SNOW'`,
  job_title 'Starter', status 'pre_start', start_date today+7) → plan
  (`kind: 'onboarding'`, `status: 'in_progress'`, start_date today+7) → two
  `plan_tasks`: one `{ title: 'E2E MW Task For Admin', owner_id: <admin
  person id>, owner_role: 'hr', phase_key: 'before_start', critical: false,
  status: 'open', sort_order: 10 }` and one unassigned `{ title: 'E2E MW
  Other Task', owner_role: 'it', phase_key: 'before_start', critical: true,
  status: 'open', sort_order: 20 }`.
Cleanup before and after, in order: `plan_tasks` (by plan id) → `plans` (by
person id) → `employment_periods` (by person id) → `people` (by full_name).

Test (one sequential flow):
1. Admin signs in → click the **My workspace** nav link (`exact: true`).
2. The profile card shows the admin's name and work email.
3. **My tasks** contains `E2E MW Task For Admin` and does NOT contain
   `E2E MW Other Task` (it is not assigned to the admin).
4. Click that row's **Mark complete** → it disappears from My tasks (assert
   count 0 for that title).
5. The access card shows the platform-admin note.
6. The projects card renders (either rows or the empty state) — assert the
   card heading 'My projects' is visible.

**Verify**: `npx playwright test e2e/my-workspace.spec.ts` → 1 passed.

### Step 6: gates

`cd app && npm test` (unit) and `npm run build` — green. Run ONLY your spec.

## Done criteria

- [ ] build + unit green; `npx playwright test e2e/my-workspace.spec.ts` → 1 passed
- [ ] `git diff --stat main` → only the 4 in-scope files
- [ ] `git diff main -- app/src/router/index.ts` shows only an added route
- [ ] Committed on `feature/013-my-workspace`

## STOP conditions

- An FK-hinted embed cannot be resolved from the generated types (report the
  Relationships entries you found).
- RLS refuses a read this plan assumes self-access covers (report the exact
  error and the query).
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
