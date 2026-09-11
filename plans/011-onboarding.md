# Plan 011: Onboarding — plans, tasks, readiness

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-010)
- **Category**: feature (development-plan item 3)

## Why this matters

Every confirmed hire already creates an onboarding plan with five dated tasks
(`public.confirm_hire`, migration 0009) — but nothing in the app shows them, so
the data is invisible. This plan delivers the screen HR actually works from:
who is starting, what is still missing before day one, and one click to
complete, block, or skip a task. Readiness is the product's core promise
(blueprint §7.5): "concrete missing items, not a misleading average percentage".

## Current state (all committed on main — read in your worktree)

Tables (see `supabase/migrations/0004_operations.sql`):

- `plans`: id, kind ('onboarding'|'offboarding'|'employment_change'),
  person_id→people, company_id→companies, employment_period_id→employment_periods,
  template_id, hr_owner_id→people, start_date, status
  ('in_progress'|'completed'|'cancelled'), completed_at, cancelled_reason,
  created_at, updated_at.
  RLS: SELECT when self (`person_id`) or `tasks.view` in the company; write
  needs `tasks.assign`.
- `plan_tasks`: id, plan_id, template_task_id, title, description,
  owner_id→people, owner_role ('hr'|'it'|'manager'|'employee'|'finance'),
  phase_key→plan_phases, due_date, critical bool, requires_evidence bool,
  status ('open'|'done'|'blocked'|'skipped'), done_by→people, done_at,
  blocked_reason, skip_reason, evidence_document_id, sort_order, updated_at.
  RLS: SELECT when you own the task, or it is your plan, or `tasks.view`;
  write needs task ownership, `tasks.complete`, or `tasks.assign`.
- `plan_phases`: key/label/sort_order — before_start, day_one, week_one,
  month_one.

**FK hints**: `plans` has TWO FKs to people (person_id, hr_owner_id) and
`plan_tasks` has TWO (owner_id, done_by) — embeds MUST be hinted. Look up the
exact constraint names in `app/src/types/database.ts` Relationships arrays
(expect `plans_person_id_fkey`, `plans_hr_owner_id_fkey`,
`plan_tasks_owner_id_fkey`, `plan_tasks_done_by_fkey`) — verify, don't guess.

App conventions: pages/dialogs as in `app/src/pages/JobPage.vue` and
`HiringRequestsPage.vue` (friendly error mapping, `.card`/`.badge`/`.field`
tokens from `app/src/styles/main.css`, `auth` store for `personId`/`isAdmin`).
E2E as in `app/e2e/hiring-pipeline.spec.ts` (service-client seeding + cleanup).

## Step 0: worktree env

FIRST git action: `git checkout -b feature/011-onboarding main` (worktrees can
start behind; branching from local `main` guarantees you have 0009/010).
Then `cp /Users/naum/Downloads/files/.env.local ./.env.local` (worktree root;
gitignored, never print values) and `cd app && npm install && npx playwright
install chromium`. E2E vite port 5199 must be free; the auth service on 8787
may already run from the main checkout (fine — `server/` is out of scope).

## Scope

**In scope**:
- `app/src/pages/OnboardingPage.vue` (create — list)
- `app/src/pages/OnboardingPlanPage.vue` (create — one plan)
- `app/src/router/index.ts` (two routes)
- `app/src/components/AppShell.vue` (one nav link)
- `app/e2e/onboarding.spec.ts` (create)

**Out of scope**: `server/`, `supabase/`, `shared/`, stores, other
pages/components/specs, `prototype/`, `plans/`, `docs/`, `.env*`.

## Git workflow

Branch `feature/011-onboarding` from main; conventional commits; no
push/merge; don't touch plans/README.md.

## Steps

### Step 1: Routes + nav

Routes (children of AppShell, after `hiring`):
`{ path: 'onboarding', name: 'onboarding', component: () => import('@/pages/OnboardingPage.vue') }`
`{ path: 'onboarding/:planId', name: 'onboarding-plan', component: () => import('@/pages/OnboardingPlanPage.vue') }`
AppShell nav: `<router-link :to="{ name: 'onboarding' }">Onboarding</router-link>`
after the Hiring link.

### Step 2: OnboardingPage.vue (the queue)

Header: eyebrow 'HR operations', h1 'Make the first day feel prepared.'

Query `plans` where `kind = 'onboarding'`, ordered by `start_date`:
`id, start_date, status, person:people!plans_person_id_fkey(full_name),
company:companies(name), plan_tasks(id, critical, status)`.

Split into two sections: **In progress** (`status = 'in_progress'`) and
**Completed** (`status = 'completed'`, collapsed below, no actions).

Each row (card or `.list-row` style): person name, company · starts
`start_date`, a readiness badge computed from the tasks:
- `criticalOpen = tasks.filter(t => t.critical && t.status !== 'done' && t.status !== 'skipped').length`
- badge: `criticalOpen ? `${criticalOpen} readiness gaps` (amber) : 'Ready for day one'` (green)
- plus small text `${done}/${total} tasks complete` where done counts
  status 'done'.
Row action: **Open plan** → route `onboarding-plan`.

Empty state: 'No onboarding plans yet. Confirming a hire creates one
automatically.'

### Step 3: OnboardingPlanPage.vue (one plan)

Load the plan:
`id, start_date, status, completed_at, person:people!plans_person_id_fkey(id, full_name),
company:companies(name), hr_owner:people!plans_hr_owner_id_fkey(full_name)`
and its tasks:
`id, title, description, owner_role, phase_key, due_date, critical, status,
blocked_reason, skip_reason, done_at, owner:people!plan_tasks_owner_id_fkey(full_name)`
ordered by `sort_order`.

Header: eyebrow 'Onboarding', h1 person's full name, meta line
`company · starts <start_date> · HR owner <name or '—'>`, readiness badge (same
rule as the list), and a link to the employee profile (route `person` with the
person id).

Tasks grouped by phase, in `plan_phases` order (load `plan_phases`:
`key, label, sort_order` ordered by sort_order; render only phases that have
tasks). Each task row shows: title, `owner_role` + owner name when set, due
date, `Required before start` when `critical`, the status badge
(done=green, blocked=amber, skipped=gray, open=blue) and, when present,
`blocked_reason` / `skip_reason`.

Actions per task (buttons; all update `plan_tasks` then reload):
- open/blocked/skipped → **Mark complete**: `{ status: 'done', done_by:
  auth.personId, done_at: new Date().toISOString() }`
- done → **Reopen**: `{ status: 'open', done_by: null, done_at: null }`
- open → **Block**: `window.prompt('Why is this blocked?')` (empty/cancel
  aborts) → `{ status: 'blocked', blocked_reason: reason }`
- open → **Skip**: prompt for a reason → `{ status: 'skipped', skip_reason: reason }`
On error show `.error-note`; if the message mentions `row-level security` or
`permission`, show 'You do not have permission to change this task.'

Plan footer: when `status === 'in_progress'` and `criticalOpen === 0`, show
**Finish onboarding** → update the plan `{ status: 'completed', completed_at:
new Date().toISOString() }` → success note. When completed, show a green
'Completed <date>' badge and no task actions… EXCEPT keep **Reopen** available
so a mistake is fixable (document this in a code comment).

### Step 4: E2E `app/e2e/onboarding.spec.ts`

Deterministic seeding with the service client (do NOT depend on the hiring
flow). Constants: person `E2E Onboarding Starter`, company Snowball
(`short_code = 'SNOW'`).

`beforeAll`/`afterAll` cleanup, in this order: `plan_tasks` (by plan ids),
`plans` (by person id), `employment_periods` (by person id), `people`
(full_name = constant).

Seed in `beforeAll` (after cleanup): person → employment_period (company
Snowball, job_title 'Starter', status 'pre_start', start_date = today+7) →
plan `{ kind: 'onboarding', person_id, company_id, employment_period_id,
start_date: today+7, status: 'in_progress' }` → three `plan_tasks`:
1. `{ title: 'E2E Documents reviewed', owner_role: 'hr', phase_key:
   'before_start', critical: true, sort_order: 10, status: 'open' }`
2. `{ title: 'E2E Laptop handed over', owner_role: 'it', phase_key:
   'before_start', critical: true, sort_order: 20, status: 'open' }`
3. `{ title: 'E2E Team introduction', owner_role: 'manager', phase_key:
   'day_one', critical: false, sort_order: 30, status: 'open' }`

Test (one sequential flow):
1. Admin signs in → **Onboarding** nav link → the row for the seeded person
   shows badge `2 readiness gaps`.
2. Open plan → h1 is the person's name; three task rows visible; the
   `before_start` and `day_one` phase headings are present.
3. **Block** the laptop task with reason `Supplier delay` (handle the prompt
   via `page.once('dialog', d => d.accept('Supplier delay'))`) → badge
   `blocked` and the reason visible; readiness badge still `2 readiness gaps`.
4. **Mark complete** both critical tasks (documents, then laptop) → readiness
   badge flips to `Ready for day one`; the non-critical task stays open.
5. **Finish onboarding** → success note and a `Completed` indicator.
6. Go back to Onboarding: the plan is no longer in "In progress" (assert the
   in-progress section does not contain the person's name).

**Verify**: `npx playwright test e2e/onboarding.spec.ts` → 1 passed.

### Step 5: gates

`cd app && npm test` (unit) and `npm run build` — green. Run ONLY your spec,
not the full suite (the reviewer runs it serially).

## Done criteria

- [ ] build + unit green; `npx playwright test e2e/onboarding.spec.ts` → 1 passed
- [ ] `git diff --stat main` → only the 5 in-scope files
- [ ] Committed on `feature/011-onboarding`

## STOP conditions

- An FK-hinted embed cannot be resolved from the generated types (report the
  Relationships entries you found).
- RLS refuses a write the plan assumes should work for a platform admin
  (report the exact error).
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
