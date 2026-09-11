# Plan 012: Home — the needs-action queue

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-011)
- **Category**: feature (development-plan item 2)

## Why this matters

The product's stated core value is one queue of pending handoffs: "Every
hiring/onboarding item has an owner and next action; HR sees overdue or
blocked handoffs in one queue" (`docs/hr-system-blueprint.md` §7.1). Today the
work is spread across Hiring and Onboarding, so nobody can see "what needs me"
in one place. This delivers the prototype's Overview screen
(`prototype/app.js`, the "Needs a decision" card) from live data.

## Current state (all committed on main — read in your worktree)

Pages exist for directory, hiring requests, job, onboarding, onboarding plan,
person profile, access editor. Nav lives in `app/src/components/AppShell.vue`;
routes in `app/src/router/index.ts` (children of AppShell; `''` currently
redirects to `directory` — **leave that redirect alone**, see Scope).

Tables/columns you need (all already used elsewhere in the app; copy the
existing query shapes):

- `hiring_requests`: status ('draft'|'submitted'|'changes_requested'|
  'approved'|'rejected'|'cancelled'), title, headcount, target_start_date,
  company_id, requested_by. FK hints to people:
  `hiring_requests_requested_by_fkey`, `hiring_requests_hiring_manager_id_fkey`.
- `applications`: stage_key ('new'|'screening'|'interview'|'offer'|'hired'|
  'rejected'|'withdrawn'), job_id, candidate_id. Embeds:
  `candidate:candidates(full_name)`, `job:jobs(id, title, company_id)`.
- `plans`: kind, status ('in_progress'|…), person_id, company_id, start_date +
  `plan_tasks(id, critical, status)`. FK hint `plans_person_id_fkey`.
- `plan_tasks`: owner_id, status, title, due_date, plan_id. FK hint
  `plan_tasks_owner_id_fkey`.
- `people`, `companies` for counts.

Verify every FK hint against the Relationships arrays in
`app/src/types/database.ts` — never guess.

Counts: `supabase.from('x').select('*', { count: 'exact', head: true })` then
read `count`.

Conventions: see `app/src/pages/OnboardingPage.vue` and `HiringRequestsPage.vue`
(cards, badges, friendly errors); tokens in `app/src/styles/main.css`
(`.card`, `.card-head`, `.badge`, `.empty`, `.error-note`); the `auth` store
exposes `personId`, `personName`, `isAdmin`.

## Step 0: worktree env

FIRST git action: `git checkout -b feature/012-home-queue main` (worktrees can
start behind main). Then `cp /Users/naum/Downloads/files/.env.local ./.env.local`
(worktree root; gitignored, never print values) and `cd app && npm install &&
npx playwright install chromium`. E2E vite port 5199 must be free; the auth
service on 8787 may already run from the main checkout (fine — out of scope).

## Scope

**In scope**:
- `app/src/pages/HomePage.vue` (create)
- `app/src/router/index.ts` (ADD one route `overview` — do NOT change the
  existing `''` → directory redirect or any other route)
- `app/src/components/AppShell.vue` (add one nav link, first in the list)
- `app/e2e/home.spec.ts` (create)

**Out of scope**: every other page/component/spec, `server/`, `supabase/`,
`shared/`, stores, `prototype/`, `plans/`, `docs/`, `.env*`. Changing the
post-login landing route is explicitly out of scope (other specs depend on it;
the reviewer will switch it separately).

## Git workflow

Branch `feature/012-home-queue` from main; conventional commits; no
push/merge; don't touch plans/README.md.

## Steps

### Step 1: Route + nav

Route (child of AppShell, FIRST in the children list after the redirect entry):
`{ path: 'overview', name: 'overview', component: () => import('@/pages/HomePage.vue') }`.
AppShell nav: `<router-link :to="{ name: 'overview' }">Overview</router-link>`
as the FIRST link.

### Step 2: HomePage.vue — header and metrics

Header: eyebrow 'Your people, connected', h1 `Welcome, <first name>.` using
`auth.personName?.split(' ')[0] ?? 'there'`, sub-line 'People, hiring
decisions, and the next step that needs an owner.'

Metrics row (four `.card`-style tiles; a simple flex/grid with the existing
tokens is fine — add component-scoped styles for the tile if needed):
- **People**: count of `people` where `archived_at is null`
- **Companies**: count of `companies` where `kind = 'company'`
- **Hiring requests**: count of `hiring_requests` where `status = 'submitted'`
- **Open onboarding tasks**: count of `plan_tasks` where `status = 'open'`

All four via `{ count: 'exact', head: true }`. RLS may return 0 for a
restricted viewer — that is correct behavior, not an error.

### Step 3: HomePage.vue — the needs-action queue

One card titled **Needs a decision** with sub-line 'Hiring approvals,
offers to confirm, and readiness gaps in one queue.' and a badge showing
`${rows.length} open` (amber when > 0, green when 0).

Build the rows from three queries, in this order:

1. **Hiring requests awaiting a decision** — `hiring_requests` where
   `status = 'submitted'`, select
   `id, title, company:companies(name), requester:people!hiring_requests_requested_by_fkey(full_name)`:
   - title: the request title
   - sub: `<company> · Hiring request${requester ? ` by <requester>` : ''}`
   - action: router-link 'Review request' → `{ name: 'hiring' }`
2. **Applications at offer** — `applications` where `stage_key = 'offer'`,
   select `id, candidate:candidates(full_name), job:jobs(id, title, company:companies(name))`:
   - title: `Offer: <candidate name>`
   - sub: `<company> · <job title> · awaiting hire confirmation`
   - action: router-link 'Open job' → `{ name: 'job', params: { jobId: job.id } }`
3. **Onboarding readiness gaps** — `plans` where `kind = 'onboarding'` and
   `status = 'in_progress'`, select
   `id, start_date, person:people!plans_person_id_fkey(full_name), company:companies(name), plan_tasks(id, critical, status)`;
   keep only plans whose critical-open count > 0 where "critical open" =
   `critical && status !== 'done' && status !== 'skipped'`:
   - title: `Onboarding: <person name>`
   - sub: `<company> · <n> critical task(s) before <start_date>`
   - action: router-link 'Open plan' → `{ name: 'onboarding-plan', params: { planId } }`

Render each row with a two-digit index (`01`, `02`, …), the title, the sub
line, and the action on the right (mirror the row markup used in
`OnboardingPage.vue`). Empty state: 'Nothing needs a decision right now.'

Below the queue, a second card **My tasks**: `plan_tasks` where
`owner_id = auth.personId` and `status = 'open'`, select
`id, title, due_date, plan_id`, ordered by `due_date` — each row links to
`{ name: 'onboarding-plan', params: { planId: plan_id } }` with label 'Open
plan'. Empty state: 'No tasks assigned to you.' (Skip the query entirely when
`auth.personId` is null.)

Load everything in parallel (`Promise.all`); a failed query shows one
`.error-note` ('Could not load the overview.') and logs detail with
`console.error` — do not leave the page blank.

**Verify**: `cd app && npm run build` → exit 0.

### Step 4: E2E `app/e2e/home.spec.ts`

Deterministic service-client seeding (model on `app/e2e/onboarding.spec.ts`).
Constants: request title `E2E Home Request`, candidate `E2E Home Candidate`
(email `e2e-home-candidate@example.test`), job title `E2E Home Job`, person
`E2E Home Starter`.

`beforeAll` (after cleanup) seeds, using Snowball (`short_code = 'SNOW'`):
- a `hiring_requests` row `{ company_id, title: 'E2E Home Request', status:
  'submitted', requested_by: null }`
- a `jobs` row `{ company_id, title: 'E2E Home Job', status: 'open' }`, a
  `candidates` row, and an `applications` row `{ job_id, company_id,
  candidate_id, stage_key: 'offer' }`
- a person + `employment_periods` row + `plans` row (`kind: 'onboarding'`,
  `status: 'in_progress'`, start_date today+7) + ONE `plan_tasks` row
  `{ title: 'E2E Home Critical Task', owner_role: 'hr', phase_key:
  'before_start', critical: true, status: 'open', sort_order: 10 }`

Cleanup (before and after), in this order: `plan_tasks` → `plans` →
`employment_periods` → `people` (by full_name) → `applications` →
`candidates` (by email) → `jobs` (by title) → `hiring_requests` (by title).

Test (one sequential flow):
1. Admin signs in, clicks the **Overview** nav link (`exact: true` — other
   links/rows may contain the word).
2. The queue card contains all three seeded rows: `E2E Home Request`,
   `Offer: E2E Home Candidate`, `Onboarding: E2E Home Starter`.
3. Click the onboarding row's **Open plan** → URL matches `/onboarding/` and
   the plan page shows `E2E Home Critical Task`.
4. Back to Overview → click the offer row's **Open job** → the job page shows
   `E2E Home Job`.
5. Assert the metrics tiles render numbers: the 'Hiring requests' tile's value
   is a digit string (`/^\d+$/`) — do not assert exact totals (live data
   varies).

**Verify**: `npx playwright test e2e/home.spec.ts` → 1 passed.

### Step 5: gates

`cd app && npm test` (unit) and `npm run build` — green. Run ONLY your spec.

## Done criteria

- [ ] build + unit green; `npx playwright test e2e/home.spec.ts` → 1 passed
- [ ] `git diff --stat main` → only the 4 in-scope files
- [ ] The `''` → directory redirect is unchanged (`git diff main -- app/src/router/index.ts` shows only an added route)
- [ ] Committed on `feature/012-home-queue`

## STOP conditions

- An FK-hinted embed cannot be resolved from the generated types (report the
  Relationships entries you found).
- A count query returns an error rather than a number for the admin user.
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
