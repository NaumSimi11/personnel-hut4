# Plan 010: Hiring workspace part B — jobs, candidates, confirm hire

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: MED (multi-page flow) /
  **Depends on**: main (post-009 + migration 0009 applied live)

## Why this matters

Completes the prototype's hiring journey: an approved request becomes a job,
candidates move through stages, and **confirm hire** turns a candidate into an
employee with an onboarding plan — in one atomic, idempotent database call.
The heavy lifting is already in the database (`public.confirm_hire(...)` RPC,
migration `supabase/migrations/0009_confirm_hire.sql` — read it; it validates,
gates on `employment.edit`, attaches-by-email or creates the person, creates
the employment period + onboarding plan, and a retry returns the first
result). The app presents the flow and surfaces refusals kindly.

## Current state (all committed on main — read in your worktree)

- `app/src/pages/HiringRequestsPage.vue` — request list with approve/reject/
  changes actions (plan 009). Requests carry `status`; approved ones are the
  entry point for this plan.
- Tables: `jobs` (company_id, hiring_request_id, title, description, status
  draft/ready/open/on_hold/filled/closed; RLS sel `jobs.view`, write
  `jobs.edit`; trigger enforces job.company = request.company), `candidates`
  (full_name, email, phone; RLS scoped via applications — a candidate with no
  application is visible/editable to `candidates.review` holders anywhere),
  `applications` (job_id, company_id NOT NULL but SERVER-DERIVED by trigger —
  pass the job's company_id to satisfy types; stage_key FK →
  application_stages: new, screening, interview, offer, hired, rejected,
  withdrawn; RLS sel `candidates.view`, write `candidates.review`),
  `application_events` (kind stage_change|note|interview_feedback,
  from/to stage, body, actor_id).
- RPC: `supabase.rpc('confirm_hire', { p_application_id, p_full_name,
  p_job_title, p_start_date, p_manager_id? })` → jsonb `{ person_id,
  employment_period_id, plan_id, already_hired }`. Errors: 'requires
  employment.edit' (42501), 'Only applications at the offer stage…',
  'already has an employment period covering that date'.
- Conventions: dialogs modeled on `RequestHireDialog.vue`; embeds with FK
  hints looked up in `app/src/types/database.ts` Relationships; friendly error
  mapping as in `HiringRequestsPage.vue`; E2E modeled on
  `app/e2e/hiring-requests.spec.ts` (service-client cleanup).

## Step 0: worktree env

`cp /Users/naum/Downloads/files/.env.local ./.env.local` (worktree root; never
print values). `cd app && npm install && npx playwright install chromium`.
Auth service on 8787 may be running from the main checkout — fine (server/ is
out of scope). E2E vite port 5199 must be free.

## Scope

**In scope**:
- `app/src/pages/JobPage.vue` (create)
- `app/src/components/AddCandidateDialog.vue` (create)
- `app/src/components/ConfirmHireDialog.vue` (create)
- `app/src/pages/HiringRequestsPage.vue` (add Prepare/Open job per approved row)
- `app/src/router/index.ts` (one route)
- `app/e2e/hiring-pipeline.spec.ts` (create)

**Out of scope**: `server/`, `supabase/`, `shared/`, stores, AppShell, other
pages/components/specs, `prototype/`, `plans/`, `docs/`, `.env*`, offers/
promotions tables (later part).

## Git workflow

Branch `feature/010-hiring-pipeline` from main; conventional commits; no
push/merge; don't touch plans/README.md.

## Steps

### Step 1: Route

Add child route `{ path: 'hiring/jobs/:jobId', name: 'job', component: () =>
import('@/pages/JobPage.vue') }`.

### Step 2: Prepare/Open job on approved requests

In `HiringRequestsPage.vue`: extend the list query to also fetch each
request's job (`jobs` has FK `jobs_hiring_request_id_fkey` — embed
`jobs!jobs_hiring_request_id_fkey(id, status)` and treat it as an array, or
query jobs separately by hiring_request_id list; your choice, keep it simple).
For rows with status `approved`:
- no job yet → button **Prepare job** → insert into `jobs` `{ company_id:
  row's company id (extend the select to include company_id), hiring_request_id,
  title: request title, description: '', status: 'open' }`, then
  `router.push({ name: 'job', params: { jobId } })`.
- job exists → button **Open job** → navigate to it.

**Verify** (after Step 3 so the page exists): `cd app && npm run build` → exit 0.

### Step 3: JobPage.vue

Load job: `id, title, description, status, company_id, company:companies(name),
request:hiring_requests(title, headcount, target_start_date)` (FK hints from
the generated types where needed). Sections:
1. **Header**: eyebrow 'Recruitment / <company>', h1 job title, status badge
   (open=green, filled=blue, else gray), back link to Hiring.
2. **Description card**: textarea + Save (update `description`; friendly error
   if refused — needs `jobs.edit`).
3. **Applications card**: header button **Add candidate** (dialog below).
   List applications for this job:
   `id, stage_key, candidate:candidates(id, full_name, email),
   employment_period_id` ordered by created_at. Each row: name/email, stage
   badge (hired=green, rejected=gray, offer=amber, else blue), and actions by
   stage: new→**Move to screening**, screening→**Move to interview**,
   interview→**Prepare offer** (sets stage 'offer'), any non-terminal →
   **Reject** (window.prompt reason). Stage changes: update `stage_key`, then
   insert `application_events` `{ application_id, kind: 'stage_change',
   from_stage_key, to_stage_key, actor_id: auth.personId }` (reject: body =
   reason). At stage `offer`: **Confirm hire** button → ConfirmHireDialog.
   After stage `hired`: no action buttons; show a link 'Open employee profile'
   → route `person` with the person id (fetch via
   `employment_periods.person_id` for `employment_period_id` — select it in
   the row query with the FK hint, e.g.
   `employment_period:employment_periods!applications_employment_period_id_fkey(person_id)`).

### Step 4: AddCandidateDialog.vue

Props `{ jobId: string, companyId: string }`. Fields (Zod): full name (2–120),
email (optional valid email), phone (optional ≤40). Submit: insert
`candidates` → insert `applications` `{ job_id, company_id, candidate_id,
stage_key: 'new' }` (company_id is server-verified by trigger). Emit `created`.

### Step 5: ConfirmHireDialog.vue

Props `{ applicationId, candidateName, jobTitle }`. Fields: full name
(prefill candidateName), position (prefill jobTitle), start date (default
today), manager (optional select of people). Submit →
`supabase.rpc('confirm_hire', { p_application_id: applicationId, p_full_name,
p_job_title, p_start_date, p_manager_id: manager || undefined })`. On success
show inside the dialog: 'Hired. Employment and the onboarding plan were
created.' + button 'Open employee profile' (route `person` with
`person_id` from the returned jsonb) + Done (emit `hired` so the page
reloads). Map errors: '42501/employment.edit' → 'Confirming hires needs
employment.edit in this company.'; 'offer stage' → show as-is; overlap →
show as-is.

**Verify**: `npm run build` → exit 0; `npm test` → unit green.

### Step 6: E2E `app/e2e/hiring-pipeline.spec.ts`

Constants: request title `E2E Pipeline Role`, candidate `E2E Pipeline
Candidate` email `e2e-pipeline-candidate@example.test`. Cleanup before/after
(service client, this order): plan_tasks+plans for the created employment;
application_events, applications, candidates by name/email; employment_periods
+ people by work_email/full name; jobs by title; hiring_requests by title.

Test (one sequential flow):
1. Service-insert an approved request: `{ company: Snowball's id, title:
   'E2E Pipeline Role', status: 'approved', requested_by: null }` (look up
   Snowball by short_code 'SNOW' or name).
2. Admin signs in → Hiring → the approved row shows **Prepare job** → click →
   lands on the job page (h1 `E2E Pipeline Role`, badge `open`).
3. **Add candidate** → name/email constants → row appears, badge `new`.
4. Advance: screening → interview → offer (three clicks, badge updates each
   time; assert `offer` + amber at the end).
5. **Confirm hire** → keep prefills, start date today → success message →
   Done → application badge `hired` and 'Open employee profile' link visible.
6. Navigate to Directory → row `E2E Pipeline Candidate`… NOTE: the employee's
   name is the confirm-dialog full name (prefilled with the candidate name) —
   assert a directory row with that name, company `Snowball`, role
   `E2E Pipeline Role`, badge `active`.
7. Open that profile → employment history shows the period; ALSO assert the
   onboarding plan exists via service client: plans row for that
   employment_period with 5 plan_tasks.

**Verify**: `npx playwright test e2e/hiring-pipeline.spec.ts` → 1 passed.

### Step 7: gates

`npm test` + `npm run build` green. Only your spec, not the full suite.

## Done criteria

- [ ] build + unit green; your E2E 1 passed
- [ ] `git diff --stat main` → only the 6 in-scope files
- [ ] Committed on `feature/010-hiring-pipeline`

## STOP conditions

- An FK-hinted embed can't be resolved from the generated types (report the
  Relationships entries).
- The confirm_hire RPC returns errors inconsistent with the migration text.
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
