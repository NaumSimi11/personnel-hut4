# Plan 009: Hiring workspace part A — hiring requests

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-008)
- **Category**: feature (development-plan item 2, first half)

## Why this matters

The hiring workspace is the product's flagship flow (prototype `prototype/app.js`
is the UI spec; blueprint §4 the rules). Part A delivers the request stage:
directors/managers request a hire; an approver decides. The database already
enforces the hard rules via triggers (`supabase/migrations/0003`,
`app.gate_hiring_request_transitions`): deciding requires `jobs.approve`,
**requesters can never decide their own request**, and `decided_by`/`decided_at`
are server-set. The app's job is to present the flow and surface those refusals
as friendly messages, never to re-implement them.

## Current state (read these in your worktree — everything is committed)

- Table `hiring_requests`: company_id, title, reason, headcount (>0), budget
  jsonb, target_start_date, hiring_manager_id→people, requested_by→people,
  status check in (draft, submitted, changes_requested, approved, rejected,
  cancelled), change_reason, decided_by, decided_at, custom jsonb. RLS: SELECT
  needs `jobs.view` in the row's company; writes need jobs.request/edit/approve.
  Trigger gates approved/rejected transitions (errcode 42501, messages
  'Deciding a hiring request requires jobs.approve' / 'Requesters cannot decide
  their own hiring request').
- App conventions: see `app/README.md`, existing pages (`DirectoryPage.vue`,
  `PersonProfilePage.vue`), stores (`auth` exposes personId/isAdmin), styles in
  `app/src/styles/main.css`. Router: `app/src/router/index.ts` (children of
  AppShell). Nav: `app/src/components/AppShell.vue` currently has one link.
- E2E conventions: `app/e2e/people.spec.ts` (login helper style, service-client
  cleanup). Playwright config sets SUPABASE_URL/SUPABASE_SECRET_KEY envs.
- Companies seeded: Praedium, Synami, Snowball, "Fourth company (rename me)".
  The signed-in test admin is a platform admin (bypasses capability checks but
  NOT the self-approval rule — the trigger applies to every signed-in user).

## Step 0: worktree env

`cp /Users/naum/Downloads/files/.env.local ./.env.local` at the worktree root
(gitignored; never print values). Install: `cd app && npm install &&
npx playwright install chromium`. Ports: E2E uses vite 5199; the auth service
on 8787 may already be running from the main checkout — that is FINE for this
plan (server/ is out of scope, the running instance is identical code);
`reuseExistingServer: true` handles both cases.

## Scope

**In scope**:
- `app/src/pages/HiringRequestsPage.vue` (create)
- `app/src/components/RequestHireDialog.vue` (create)
- `app/src/router/index.ts` (one route)
- `app/src/components/AppShell.vue` (one nav link)
- `app/e2e/hiring-requests.spec.ts` (create)

**Out of scope**: jobs/candidates/offers/promotions (part B), `server/`,
`supabase/`, `shared/`, stores, other pages/components/specs, `prototype/`,
`plans/`, `docs/`, `.env*`.

## Git workflow

Branch `feature/009-hiring-requests` from main; conventional commits; no push,
no merge.

## Steps

### Step 1: Route + nav

Router: add child route `{ path: 'hiring', name: 'hiring', component: () =>
import('@/pages/HiringRequestsPage.vue') }` after `directory`. AppShell nav:
add `<router-link :to="{ name: 'hiring' }">Hiring</router-link>` after the
People link. **Verify**: `cd app && npm run build` → exit 0 (after Step 2
creates the page — build once the page exists).

### Step 2: RequestHireDialog.vue

Native `<dialog>` styled like `AddPersonDialog.vue` (copy its shell). Fields,
Zod-validated: company (select, companies kind='company' ordered by name),
job title (2–120), reason (textarea, optional ≤2000), headcount (number ≥1,
default 1), target start date (date, optional), hiring manager (select of
people — load `people` id+full_name ordered by name, optional). Submit inserts
`hiring_requests` with `status: 'submitted'` and `requested_by:
auth.personId`. Friendly errors via `.error-note`; emit `created`; expose
`open()`.

### Step 3: HiringRequestsPage.vue

Header: eyebrow "Recruitment", h1 "One role. Every handoff connected." +
"Request a hire" button (always visible; RLS refuses unauthorized inserts and
the dialog surfaces it). Card list of requests: select
`id, title, reason, headcount, target_start_date, status, change_reason,
requested_by, decided_at, company:companies(name),
requester:people!hiring_requests_requested_by_fkey(full_name),
manager:people!hiring_requests_hiring_manager_id_fkey(full_name)` ordered by
created_at desc. NOTE the FK-disambiguation hints — `hiring_requests` has THREE
FKs to people (requested_by, hiring_manager_id, decided_by); an unhinted embed
will fail. If the hint name doesn't match, discover the real constraint names
with `grep -n 'references public.people' supabase/migrations/0003_recruitment.sql`
and the generated types in `app/src/types/database.ts` (Relationships arrays
list the exact fkey names) — adjust, don't guess.

Each row (reuse `.card` + row patterns): title, company, requester name,
headcount, target date, status badge (submitted=amber, approved=green,
rejected=gray, changes_requested=blue), change_reason shown when present.
Actions per row while status is `submitted` or `changes_requested`:
- **Approve** → `update({ status: 'approved' })`
- **Request changes** → small inline form or `window.prompt` for the reason →
  `update({ status: 'changes_requested', change_reason: reason })`
- **Reject** → prompt for reason → `update({ status: 'rejected', change_reason: reason })`
On update error: if the message contains 'jobs.approve' show
'Approving needs the jobs.approve capability in this company.'; if it contains
'their own' show 'You requested this hire — a different approver must decide it.';
otherwise show the raw message. Reload the list after any change. Empty state:
'No hiring requests yet. Request a hire to start the journey.'

**Verify**: `npm run build` → exit 0.

### Step 4: E2E `app/e2e/hiring-requests.spec.ts`

Model on `people.spec.ts`. Constants: title `E2E Role Alpha` (UI-created) and
`E2E Role Beta` (service-created). Cleanup before/after: delete
`hiring_requests` where title in both constants.

One sequential test:
1. Admin signs in, opens Hiring via the nav link.
2. "Request a hire" → company Snowball, title `E2E Role Alpha`, headcount 1 →
   row appears with badge `submitted` and the admin's name as requester.
3. Click its **Approve** → expect the friendly self-approval error (the admin
   requested it) and badge STILL `submitted`.
4. Service client inserts `E2E Role Beta` (company Snowball, status
   'submitted', requested_by null). Reload page → row appears.
5. Approve `E2E Role Beta` → badge `approved`.
6. **Request changes** on `E2E Role Alpha` with reason `Need budget range` →
   badge `changes_requested` and the reason visible.

**Verify**: `npx playwright test e2e/hiring-requests.spec.ts` → 1 passed.

### Step 5: gates

`cd app && npm test` (unit) and `npm run build` green. Do NOT run the full
Playwright suite (reviewer runs it serially).

## Done criteria

- [ ] app build + unit green
- [ ] `npx playwright test e2e/hiring-requests.spec.ts` → 1 passed
- [ ] `git diff --stat main` touches only the 5 in-scope files
- [ ] Committed on `feature/009-hiring-requests`

## STOP conditions

- The FK-hinted embed cannot be made to work from the generated types (report
  the Relationships entries you found).
- E2E fails twice on live-data state rather than your code.
- Anything requires an out-of-scope file.

## Report format

```
STATUS: COMPLETE | STOPPED
STEPS: per step — done/skipped + verification result
STOPPED BECAUSE: (only if STOPPED)
FILES CHANGED: list
NOTES: deviations/surprises + worktree path + branch + final commit SHA
```
