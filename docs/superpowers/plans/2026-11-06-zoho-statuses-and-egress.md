# Zoho statuses, re-import and Free-plan egress — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PeopleOS's hiring pipeline runs on Zoho's 4 stages and 37 statuses. Each status carries an outcome. The Zoho Candidate-Job View CSV is re-imported with CVs and job notes, and no screen reads unbounded data from Supabase.

**Architecture:**
- **Database.** Three migrations:
  - **0095** replaces the vocabulary. It adds `outcome` to statuses, maintains a denormalised `applications.in_play` with a trigger, and adds a closure mark.
  - **0096** rewrites every function that reads stages to use `in_play` and outcome. Picking a status now moves the stage too.
  - **0097** adds a server-side summary for Home and Openings, plus the import function.
- **App.** Hiring libraries switch from stage sets to `in_play` and outcome, lists page on the server, and lookups are cached.
- **Import.** A Node extractor turns the CSV into a JSON payload for one SQL function (dry-run, then commit). A Node script re-attaches CVs from the 2026-11-05 backup.

**Tech Stack:** Postgres 17 on Supabase (SQL migrations, plpgsql), Vue 3 + Pinia + supabase-js + Zod, Fastify/Node + tsx, Vitest, Playwright, `supabase/tests/local-verify.sh` (Docker Postgres 16 + `smoke.sql`).

**Spec:** `docs/superpowers/specs/2026-11-05-zoho-statuses-and-egress-design.md` (approved 2026-11-06). Read it first. Its status table is normative.

## Global Constraints

- **Stages:** stage keys are `screening`, `interview`, `offer` (label **"Offered"**) and `hired`, in that order. The stages `new`, `rejected` and `withdrawn` are deleted. `applications.stage_key` defaults to `screening`.
- **Statuses:** exactly the 37 statuses in the table under Task 1, with those keys, labels, stages, sort orders and outcomes. Labels are Zoho's text byte-for-byte. All 40 current statuses are deleted (prod has 0 applications and 0 events on 2026-11-05).
- **Outcome:** `outcome ∈ ('open','rejected','withdrew','hired')`.
- **In play:** `in_play = (status outcome = 'open') and closed_at is null`. Every "is it finished / still open" question reads `in_play`, never a stage list. The strings `'rejected'` and `'withdrawn'` as **stage** keys must not survive anywhere in `app/src`, `server/src` or live functions.
- **Rule keys:** `applied`, `sourced`, `contact_attempted` and `contacted` keep their keys and the `application_sub_statuses_rule_keys_stay` CHECK. Default status on insert:
  - source `head_hunt`, `linkedin_profile` or `imported` → `sourced`
  - any other source → `applied`
  - any other stage → that stage's first status by `sort_order` (for `hired`, that's `hired`)
- **Contact rules:** only the import sets `do_not_contact` and `contact_later`. When a candidate's rows disagree, `do_not_contact` wins. The reason is `Zoho: <status label>`.
- **Jobs:** the import never writes to `jobs`. Jobs match by `jobs.custom->'zoho'->>'display_id'` (e.g. `ZR_95_JOB`).
- **Egress budget:** no request a screen makes returns more than about 100 rows or about 100 KB. The app never selects `extracted_text`.
- **Personal data:** never commit the CSV, `file/`, `.zoho-*` payloads or `~/Downloads/peopleos-backup-2026-11-05/`. Add `file/` and `.zoho-job-view*.json` to `.gitignore` in Task 9.
- **Production:** a push to `main` deploys `peopleos.hut4.com`. Apply a single migration with `psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/<file>`. **Never** run anything against prod before Task 12, and Task 12 only after the user approves the release.
- **Commits:** conventional (`feat:`, `fix:`…). Stage files by explicit path, never `git add -A`. End each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A status picked in a different stage.** Picking "Offer-Made" for a Screening candidate moves them to Offered in one step, with one `stage_change` event that names both statuses. It must never be refused as "not a status of this stage". Test: Task 2 smoke `0096-a`.
2. **The same candidate twice on one job.** The unique index uses `in_play`, so a candidate whose first application was closed or rejected can be added again. A second in-play one is still refused. Test: Task 1 smoke `0095-c`.
3. **A closed job, then a status set on its candidate.** `set_application_status` on an application with `closed_at` set is refused with "This job was closed on <date>. Reopen the job first.". Test: Task 2 smoke `0096-c`.
4. **A careers applicant after the change.** A public application lands on Screening / New (`applied`) and is in play, and the duplicate check in `server/src/careers.ts` uses `in_play`. Test: Task 3.
5. **Running the import twice.** A second `--commit` with the same payload creates 0 candidates, 0 applications and 0 notes (provider dedupe), and sends no notifications. Test: Task 10 smoke `0097-d`.

---

### Task 1: Migration 0095 — the Zoho vocabulary, outcome, `in_play`, closure mark

**Files:**
- Create: `supabase/migrations/0095_zoho_statuses.sql`
- Modify: `supabase/tests/smoke.sql` (append block `0095`)

**Interfaces:**
- Produces:
  - `application_sub_statuses.outcome text not null check (outcome in ('open','rejected','withdrew','hired'))`
  - `applications.in_play boolean not null default true`
  - `applications.closed_at timestamptz null`
  - `applications.closed_reason text null` (≤ 2000)
  - `app.default_sub_status(p_stage text, p_source_key text) returns text` (rules above)
  - trigger `t3_sub_status` → `app.applications_sub_status()`. It keeps today's guard (status must belong to the row's stage and be unretired) and also sets `new.in_play`.
  - unique index `applications_one_open_per_candidate on (job_id, candidate_id) where in_play`
  - partial index `applications_in_play_job_idx on (job_id) where in_play`

Seed (one transaction; first `raise exception` unless `select count(*) from applications` = 0 and `select count(*) from application_events` = 0):

| sort | key | label | stage | outcome |
|---|---|---|---|---|
| 10 | applied | New | screening | open |
| 20 | sourced | Associated | screening | open |
| 30 | not_contacted | Not Contacted | screening | open |
| 40 | contact_attempted | Attempted to Contact | screening | open |
| 50 | contacted | Contacted | screening | open |
| 60 | no_response | Not responding | screening | withdrew |
| 70 | interested | Interested | screening | open |
| 80 | not_interested | Not Interested | screening | withdrew |
| 90 | qualified | Qualified | screening | open |
| 100 | waiting_for_evaluation | Waiting-for-Evaluation | screening | open |
| 110 | unqualified | Unqualified | screening | rejected |
| 120 | rejected_for_interview | Rejected-for-Interview | screening | rejected |
| 130 | contact_in_future | Contact in Future | screening | withdrew |
| 140 | never_contact | NEVER to be contacted again | screening | withdrew |
| 10 | interview_to_schedule | Interview-to-be-Scheduled | interview | open |
| 20 | interview_scheduled | Interview-Scheduled | interview | open |
| 30 | interview_in_progress | Interview-in-Progress | interview | open |
| 40 | interview_hr | Interview 1 - HR | interview | open |
| 50 | interview_stakeholders | Interview 2 - Stakeholders | interview | open |
| 60 | interview_other_stakeholder | Interview 3 - Other stakeholder | interview | open |
| 70 | interview_other_stakeholders | Interview 4 - Other stakeholders | interview | open |
| 80 | interview_task | Task | interview | open |
| 90 | no_show | No-Show | interview | open |
| 100 | interview_feedback_due | Feedback to be provided from an Interview | interview | open |
| 110 | submitted_to_manager | Submitted-to-hiring manager | interview | open |
| 120 | interview_on_hold | On-Hold | interview | open |
| 130 | rejected_general | Rejected | interview | rejected |
| 140 | rejected_by_hr | Rejected by HR | interview | rejected |
| 150 | rejected_by_manager | Rejected by hiring manager | interview | rejected |
| 160 | rejected_after_interview | Rejected by Manager - Interview | interview | rejected |
| 170 | rejected_hirable | Rejected-Hirable | interview | rejected |
| 180 | candidate_withdrew | Withdraw Application | interview | withdrew |
| 10 | to_be_offered | To-be-Offered | offer | open |
| 20 | offer_made | Offer-Made | offer | open |
| 30 | offer_declined | Offer-Declined | offer | withdrew |
| 40 | offer_withdrawn | Offer-Withdrawn | offer | rejected |
| 10 | hired | Hired | hired | hired |

Order inside the migration:
1. Guard.
2. Add the columns.
3. `delete from application_sub_statuses`.
4. Delete stages `new`, `rejected` and `withdrawn`. Relabel `offer` → "Offered". Set sort orders to 10/20/30/40.
5. Set the column default `screening`.
6. Insert the seed.
7. Set outcome not null.
8. Replace `default_sub_status` and the trigger function.
9. Rebuild the unique index.
10. Add the `in_play` index.

Renaming a status stays allowed. **Changing `outcome` on a status that any application uses** is refused by a `before update` trigger on `application_sub_statuses` with the message `"<label>" is in use — its outcome cannot change.`.

- [ ] **Step 1: Write failing smoke block `0095` in `supabase/tests/smoke.sql`.** It asserts:
  - `(select count(*) from application_sub_statuses) = 37`
  - `(select string_agg(key, ',' order by sort_order) from application_stages) = 'screening,interview,offer,hired'`
  - **0095-a:** an application inserted with no stage is `stage_key='screening'`, `sub_status_key='applied'`, `in_play=true`, and with `source_key='head_hunt'` it is `sourced`.
  - **0095-b:** updating it to `stage_key='interview', sub_status_key='rejected_general'` gives `in_play=false`, and setting `closed_at` on an open one gives `in_play=false`.
  - **0095-c:** the same candidate/job inserted again succeeds after 0095-b. A third insert while the second is in play raises `unique_violation`.
  - **0095-d:** `update application_sub_statuses set outcome='open' where key='rejected_general'` raises while used.
  - `update ... set archived_at=now() where key='applied'` raises (rule keys).
- [ ] **Step 2: Run `./supabase/tests/local-verify.sh`.** Expected: FAIL at block 0095. Earlier blocks may also fail on the stage keys this removes. That is Task 4's job, so to run only the new block while iterating, temporarily run the migrations plus `smoke.sql` from the `-- ==== 0095` marker.
- [ ] **Step 3: Write `0095_zoho_statuses.sql`** as specified above.
- [ ] **Step 4: Re-run.** Expected: block 0095 passes.
- [ ] **Step 5: Commit** `feat: Zoho stages and statuses with an outcome; in_play and the closure mark (migration 0095)`.

### Task 2: Migration 0096 — every function on `in_play`; a status picks its stage

**Files:**
- Create: `supabase/migrations/0096_functions_on_in_play.sql`
- Modify: `supabase/tests/smoke.sql` (append block `0096`)

**Interfaces:**
- Consumes: Task 1 columns.
- Produces:
  - `public.set_application_status(p_application_ids uuid[], p_sub_status_key text, p_note text) returns jsonb`. The signature is unchanged. The status's own stage becomes the row's stage. It writes one `application_events` row:
    - `kind` is `'stage_change'` when the stage changes, else `'status_change'` (`'outreach'` when both old and new are in `screening`)
    - it carries from/to stage and from/to sub-status, with `body` = note
    - it refuses when `closed_at` is set: `This job was closed on YYYY-MM-DD. Reopen the job first.`
    - it refuses a `hired` status: `Hire through the offer — "Hired" is set when the offer is accepted.`
    - it returns `{"set": n}`
  - `public.close_jobs(p_job_ids uuid[], p_reason text, p_withdraw boolean)`: same signature and messages. With `p_withdraw`, in-play applications get `closed_at = now()` and `closed_reason = v_reason`, their status is untouched, and one `status_change` event per application has body = reason. Returns `{closed, already_closed, withdrawn}` as today.
  - `public.withdraw_in_play(...)` and `app.applications_fill_job()` (0090) apply the same closure mark with `closed_reason = 'Position filled.'`.
  - Rewritten to read `in_play` / outcome instead of stage lists, behaviour otherwise unchanged:
    - `app.notify_application_owner`
    - `app.not_responding` (screening statuses `sourced`, `contact_attempted`, `contacted`)
    - `public.log_outreach` (allowed when the stage is `screening`)
    - `app.open_application` (inserts with no stage, so default)
    - `public.detach_candidate_from_job`
    - `public.recruitment_report` (funnel = the 4 stages, plus `rejected`/`withdrew` counts by outcome)
    - `app.report_hires`
    - `public.create_employee`
    - `public.link_hired_application`
    - `public.remove_sub_status`
    - `public.sub_status_usage`
  - Dropped: `public.import_zoho_recruit(jsonb, boolean)`, `public.import_zoho_history(jsonb, boolean)`, `app.backfill_sub_statuses()`, `app.reason_sub_status(text, text)`, `app.zoho_sub_status(text)`.
  - Also: `0018`'s auto-withdraw path (find it with the check below) uses the closure mark.

- [ ] **Step 1: List every live function that still names an old stage.** Run it on the local DB after Task 1, and keep the list in the commit body:

```sql
select n.nspname||'.'||p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('public','app') and p.prosrc ~ '''(new|rejected|withdrawn)''' and p.prosrc ~ 'stage';
```

- [ ] **Step 2: Write failing smoke block `0096`:**
  - **0096-a:** `set_application_status([id], 'offer_made', 'ok')` on a screening application gives `stage_key='offer'`, and the newest event is `kind='stage_change'`, `from_stage_key='screening'`, `to_stage_key='offer'`, `to_sub_status_key='offer_made'`.
  - **0096-b:** `close_jobs([job], 'Budget cut', true)` leaves `sub_status_key` unchanged and sets `closed_at`, `closed_reason='Budget cut'` and `in_play=false`, and `withdrawn` = the number that were in play.
  - **0096-c:** `set_application_status` on that row raises `This job was closed on`.
  - **0096-d:** `set_application_status([id], 'hired', null)` raises.
  - **0096-e:** filling a job's headcount (the 0090 path) marks the others with `closed_reason='Position filled.'`.
  - **0096-f:** the Step 1 query returns 0 rows.
- [ ] **Step 3: Run `local-verify.sh`.** Expected: FAIL in 0096.
- [ ] **Step 4: Write `0096_functions_on_in_play.sql`.** Start each function from its latest live definition (`select pg_get_functiondef('<name>'::regproc)` on the local DB) and change only the stage logic.
- [ ] **Step 5: Re-run.** Expected: 0095 and 0096 pass.
- [ ] **Step 6: Commit** `feat: functions read in_play; a status moves its application; closing a job marks, never relabels (migration 0096)`.

### Task 3: Server — careers intake on `in_play`

**Files:**
- Modify: `server/src/careers.ts:210-215`, `server/src/careersRoutes.ts:177`
- Test: `server/src/careers.test.ts`

**Interfaces:** `isDuplicateApplication(existing: { in_play: boolean }[]): boolean`.

- [ ] **Step 1: Failing tests** in `careers.test.ts`:
  - `isDuplicateApplication([{ in_play: false }])` is `false`
  - `isDuplicateApplication([{ in_play: false }, { in_play: true }])` is `true`
- [ ] **Step 2:** Run `cd server && npx vitest run src/careers.test.ts`. Expected: FAIL (type or value).
- [ ] **Step 3: Implement.** Delete `TERMINAL`. The route selects `in_play, candidate:candidates!inner(email)`. The insert stays as it is (the default stage and status apply).
- [ ] **Step 4:** Run `cd server && npm test`. Expected: PASS.
- [ ] **Step 5: Commit** `fix: careers duplicate check reads in_play`.

### Task 4: Bring the old smoke blocks to the new model

**Files:** Modify: `supabase/tests/smoke.sql`, `supabase/tests/delete-job-application.sql`

- [ ] **Step 1:** Run `./supabase/tests/local-verify.sh` and note the first failing block.
- [ ] **Step 2: Fix that block's fixture or assertion to the new model, never the migration:**
  - `stage_key='new'` → `'screening'`
  - a "rejected"/"withdrawn" row → a status with that outcome (`rejected_general` / `candidate_withdrew` in `interview`)
  - asserting the stage of a withdrawn row → asserting `in_play=false` and `closed_at`
  - an assertion about the dropped Zoho import functions or backfill → delete it, with a one-line comment naming migration 0096
- [ ] **Step 3:** Repeat Steps 1–2 until the run ends with `All migrations applied and smoke tests passed.`
- [ ] **Step 4: Commit** `test: smoke suite on Zoho stages and in_play`.

### Task 5: App hiring libraries on `in_play` and outcome

**Files:**
- Modify:
  - `app/src/lib/stageStatuses.ts` (`STATUS_STAGES`, `OPEN_STAGES`, `OUTREACH_STAGES`)
  - `app/src/lib/outreach.ts` (`SUB_STATUS_STAGES = ['screening']`)
  - `app/src/lib/dashboard.ts` (`PIPELINE_STAGES`, `CLOSED_STAGES`, `stageLabel`)
  - `app/src/lib/hiringBoard.ts` (`BoardColumnKey`, `BOARD_COLUMNS`, `columnOf`)
  - `app/src/lib/hiringTabs.ts` (`CLOSED_STAGES`)
  - `app/src/lib/hiringJourney.ts`
  - `app/src/lib/reporting.ts` (`STAGE_ORDER`)
  - `app/src/lib/detachApplication.ts`
  - `app/src/lib/hiringLabels.ts` (`SubStatusRow.outcome`)
- Regenerate: `app/src/types/database.ts` (`npx supabase gen types typescript --db-url <local verify URL>`)
- Test: the matching `*.test.ts` beside each file

**Interfaces (produces):**
- `export const STAGES = ['screening','interview','offer','hired'] as const` and `export type StageKey = (typeof STAGES)[number]` in `stageStatuses.ts`. Every other module imports `STAGES` from there. No module keeps its own list.
- `export type Outcome = 'open' | 'rejected' | 'withdrew' | 'hired'` and `SubStatusRow = LookupRow & { stage_key: string; outcome: Outcome; archived_at: string | null }` in `hiringLabels.ts`.
- `export const STAGE_LABEL: Record<StageKey, string> = { screening: 'Screening', interview: 'Interview', offer: 'Offered', hired: 'Hired' }` in `stageStatuses.ts`. `dashboard.stageLabel` reads it.
- Row types that today carry `stage_key` for open/closed logic gain `in_play: boolean`: `ApplicationLite`, `OpeningApplicationLite`, `ApplicantLite`, `CandidateAction`, `BoardRow` inputs and `DetachTarget`. Every "open" filter becomes `a.in_play`.
- `BoardColumnKey = 'screening' | 'interview' | 'offer' | 'hired' | 'closed'`. An application with `in_play=false` and stage ≠ `hired` goes in `closed`.
- `filterStagesFor('live')` returns `STAGES` minus `hired`. `filterStagesFor('not_responding')` returns `['screening']`.
- `export function statusesByOutcome(rows: ReadonlyArray<SubStatusRow>, outcome: Outcome): SubStatus[]` in `stageStatuses.ts` (live rows only, stage then sort order). Task 6 uses it for the Reject and Withdraw pickers.

- [ ] **Step 1: Rewrite the failing tests first, file by file.** Keep each test's intent and change only stages and fixtures. New assertions:
  - `jobBoard` counts a `{stage_key:'interview', in_play:false}` row under `closed`
  - `applicantsInProgress([{stage_key:'screening', in_play:false}])` is `0`
  - `statusesByOutcome(rows,'rejected')` returns `unqualified, rejected_for_interview` before `rejected_general…` (stage order)
  - `STAGE_LABEL.offer === 'Offered'`
- [ ] **Step 2:** Run `cd app && npx vitest run src/lib`. Expected: FAIL.
- [ ] **Step 3: Implement.** Then check: `grep -rnE "'(new|rejected|withdrawn)'" app/src/lib | grep -v test` shows only non-hiring uses (leave, compensation, access, requests).
- [ ] **Step 4:** Run `cd app && npm test && npm run typecheck`. Expected: lib tests PASS. Typecheck errors may remain only in `.vue` files (Task 6).
- [ ] **Step 5: Commit** `refactor: hiring libraries on Zoho stages, outcome and in_play`.

### Task 6: App screens — one status door, the outcome on Labels

**Files:**
- Modify:
  - `app/src/pages/ApplicationPage.vue` (lines ~150-180 and ~440-470: direct `update({ stage_key })`)
  - `app/src/pages/JobPage.vue` (~530-575 `moveToScreening`/`moveToInterview`/`reject`, ~452 `withdrawRest`, ~212-249 counts, ~992-995 buttons)
  - `app/src/components/RejectApplicationDialog.vue`
  - `app/src/components/StatusDialog.vue`
  - `app/src/components/CandidateHandoffDialog.vue`
  - `app/src/components/ApplicationOfferCard.vue`
  - `app/src/components/hiring/LabelsPanel.vue`
  - `app/src/components/hiring/RemoveStatusDialog.vue`
  - `app/src/components/home/RecruitmentSnapshot.vue`
  - `app/src/components/tasks/MyTasksCard.vue`
  - `app/src/pages/CandidatePage.vue`
  - `app/src/pages/HiringRequestsPage.vue` (hiring parts only)
- Test: `app/e2e/candidate-review.spec.ts`, `app/e2e/close-openings.spec.ts` (update in place)

**Behaviour:**
- **No client code writes `stage_key` any more.** Every move, reject and withdraw calls `supabase.rpc('set_application_status', { p_application_ids, p_sub_status_key, p_note })`.
- **The status picker** lists all live statuses grouped by stage (`statusFilterGroups`). Picking one moves the stage.
- **Reject** opens the picker limited to `statusesByOutcome(rows,'rejected')`, and **Withdraw** to `'withdrew'`. The note is optional and goes into the event body.
- **"Move to Interview"** and similar quick buttons set the target stage's first open status (`interview_to_schedule`, `to_be_offered`).
- **A closed-marked application** shows `Job closed — <closed_reason> (<date>)` where the status chip is, and its status controls are disabled.
- **Labels → Add status** requires an outcome: a radio with "Still in play", "Rejected" and "Withdrew". The labels are copy and the values are the `Outcome` keys. `hired` is not offered. The outcome is read-only on existing statuses.

- [ ] **Step 1:** Update the two E2E specs to the new flow: reject via the picker sets "Rejected by HR" and the row shows it, and closing an opening with "withdraw the rest" shows "Job closed — <reason>". They run only against a local or staging project, since E2E refuses prod.
- [ ] **Step 2: Implement.** Then check: `grep -rnE "stage_key:|update\(\{ *stage_key" app/src --include='*.vue'` returns no writes.
- [ ] **Step 3:** Run `cd app && npm run typecheck && npm test`. Expected: PASS.
- [ ] **Step 4: Commit** `feat: one status door moves stages; Labels asks for the outcome`.

### Task 7: Egress — server-side summaries for Home and Openings

**Files:**
- Create: `supabase/migrations/0097_hiring_summary_and_import.sql` (this task writes the summary part; Task 10 appends the import part)
- Modify:
  - `app/src/pages/HomePage.vue` (remove `loadPipelineApplications` and its `pageAll`)
  - `app/src/components/home/RecruitmentSnapshot.vue`
  - `app/src/components/home/HiringBoard.vue`
  - `app/src/components/hiring/JobOpeningsPanel.vue` (remove `loadCountedApplications`)
  - `app/src/lib/dashboard.ts`
  - `app/src/lib/hiringBoard.ts`
- Test: `supabase/tests/smoke.sql` block `0097-summary`, `app/src/lib/dashboard.test.ts`, `app/src/lib/hiringBoard.test.ts`

**Interfaces:**
- `public.hiring_summary() returns jsonb` (security definer; every count limited to companies where the caller has `candidates.view`, via `app.has_capability`). It returns:

```json
{ "by_job": [{ "job_id": "uuid", "stage_key": "screening", "in_play": true, "count": 12, "last_received_at": "ts" }],
  "not_responding": 7,
  "recent": [{ "application_id": "uuid", "candidate_name": "…", "job_title": "…", "company_name": "…", "stage_key": "…", "received_at": "ts" }] }
```

  `by_job` covers jobs whose status is in (`ready`, `open`, `on_hold`). `recent` holds the 5 newest in-play applications.
- App: `export type HiringSummary` plus a Zod parser `parseHiringSummary(raw: unknown): HiringSummary` in `dashboard.ts`. `pipelineCounts`, `applicantsInProgress`, `openPositions`, `recentApplicants`, `notRespondingCount` and `jobBoard` take `HiringSummary` (and jobs) instead of an application array.
- Openings: `public.opening_counts(p_job_ids uuid[]) returns table(job_id uuid, in_play int, total int)`, called with the ids of the jobs page already loaded.

- [ ] **Step 1: Failing smoke `0097-summary`.** With a viewer who has `candidates.view` in Company A only, `hiring_summary()->'by_job'` contains no Company B job, and `not_responding` equals `app.not_responding` counted over A.
- [ ] **Step 2: Failing vitest.** `jobBoard(summaryFixture, jobs, today)` gives the same rows the old application-array fixture gave, rewritten as a summary.
- [ ] **Step 3: Implement** the SQL and the app changes.
- [ ] **Step 4:** Run `local-verify.sh` and `cd app && npm test && npm run typecheck`. Expected: PASS.
- [ ] **Step 5: Commit** `perf: Home and Openings read counts from the database, not every application (migration 0097, part 1)`.

### Task 8: Egress — paged lists, cached lookups, quiet notifications, a guard

**Files:**
- Modify: `app/src/pages/JobPage.vue` (`loadApplications`), `app/src/components/hiring/ApplicantsPanel.vue` (`load`), `app/src/stores/notifications.ts`, `app/src/components/AppShell.vue`
- Create: `app/src/stores/hiringLookups.ts`, `app/src/lib/noUnboundedReads.test.ts`
- Modify (to use the store instead of their own lookup selects): `AddCandidateDialog.vue`, `SourceToJobDialog.vue`, `hiring/TalentPoolPanel.vue`, `hiring/ApplicantsPanel.vue`, `hiring/LabelsPanel.vue` (reload after edits via `refresh()`), `pages/CandidatePage.vue`, `pages/ApplicationPage.vue`, `pages/JobPage.vue`

**Interfaces:**
- `useHiringLookupsStore()` exposes:
  - `{ stages: Ref<StageRow[]>, statuses: Ref<SubStatusRow[]>, sources: Ref<LookupRow[]> }`
  - `ensure(): Promise<void>` (loads once per session, and concurrent callers share one request)
  - `refresh(): Promise<void>`
- `export const LIST_PAGE = 50` in `app/src/lib/pageAll.ts`. Delete `pageAll` and `MAX_PAGES` once nothing imports them.
- **JobPage applications** load `LIST_PAGE` rows via `.range()` with `count: 'exact'`. Filters (stage, status, in play) run in the query, and "Load more" appends. Header counts come from `opening_counts([jobId])` (Task 7).
- **ApplicantsPanel** gets the same treatment: replace `PAGE_CAP` with `LIST_PAGE`, add "Load more" and a server-side name search (`candidate.full_name ilike`).
- **Notifications:**
  - `refreshUnread(): Promise<void>` runs `select('id', { count: 'exact', head: true }).is('read_at', null).is('archived_at', null)` every `POLL_MS` (60 s) only while `document.visibilityState === 'visible'`, and once on `visibilitychange` to visible.
  - The full `load()` (100 rows) runs only when the bell menu or the Notifications page opens.
  - `unread` becomes a number ref.

- [ ] **Step 1: Failing guard test `noUnboundedReads.test.ts`.** It reads every `app/src/**/*.{ts,vue}` file. For each `.from('applications')`, `.from('candidates')`, `.from('application_events')` and `.from('candidate_notes')` chain that contains `.select(`, the 400 characters after it must contain `.range(`, `.limit(`, `.single(`, `.maybeSingle(`, `head: true`, or an `.eq('id'` / `.eq('candidate_id'` / `.eq('application_id'` on a single row. It fails listing `file:line`. An inline `// bounded: <reason>` comment on the `.from(` line exempts a chain.
- [ ] **Step 2: Failing store test.** Two concurrent `ensure()` calls make one request each for stages, statuses and sources (mock `supabase.from`).
- [ ] **Step 3: Failing notifications test.** With `visibilityState='hidden'`, advancing fake timers by 5 minutes makes 0 requests. With `'visible'`, it makes 5 head-only count requests and 0 list requests.
- [ ] **Step 4: Implement.** Then confirm `grep -rn "extracted_text" app/src --include='*.vue' --include='*.ts' | grep -v types/database.ts` is empty.
- [ ] **Step 5:** Run `cd app && npm test && npm run typecheck`. Expected: PASS.
- [ ] **Step 6: Commit** `perf: lists page in 50s, lookups load once, the bell counts only while visible`.

### Task 9: Import extractor — the Candidate-Job View CSV → payload

**Files:**
- Create: `server/src/zohoRecruit/jobView.ts`, `server/src/zohoRecruit/jobViewStatuses.ts`, `server/scripts/zoho-job-view-extract.ts`, fixture `server/src/zohoRecruit/fixtures/job-view.csv` (6 synthetic rows, invented names)
- Modify: `server/src/zohoRecruit/dates.ts` (add `parseLocalMinute`), `server/package.json` (script), `.gitignore`
- Test: `server/src/zohoRecruit/jobView.test.ts`, `server/src/zohoRecruit/jobViewStatuses.test.ts`, `server/src/zohoRecruit/dates.test.ts`

**Interfaces:**
- `ZOHO_STATUS_KEY: Readonly<Record<string, string>>` in `jobViewStatuses.ts` maps each Zoho label to its key. It holds all 37 labels, plus `'Not contacted' → 'not_contacted'`.
- `parseLocalMinute(value: string, tz: string): string | null` turns `'2023-02-13 15:38'` into an ISO UTC string for `Europe/Skopje`. Blank or malformed → `null`.
- `splitNotesLog(log: string, tz: string): Array<{ occurred_at: string | null; kind_label: string; author_name: string; body: string }>`. Entries are separated by blank lines, each with the header `[YYYY-MM-DD HH:MM] <Kind> – <Author>:` (en dash) followed by the body lines. An entry that doesn't match is returned with `kind_label: ''`, `author_name: ''` and the whole text as `body`, and is counted as a problem.
- `buildJobViewPayload(rows: CsvRow[], opts: { tz: string }): JobViewResult`, where `JobViewResult = { payload: JobViewPayload; counts: { candidates: number; applications: number; notes: number; byStatus: Record<string, number> }; problems: Array<{ ref: string; message: string }> }` and:

```ts
type JobViewPayload = {
  candidates: Array<{ zoho_id: string; full_name: string; email: string | null; phone: string | null; linkedin_url: string | null;
    skills: string[]; source_key: string; owner_name: string | null; last_activity_at: string | null;
    contact_rule: null | { rule: 'do_not_contact' | 'contact_later'; reason: string }; custom: { zoho: Record<string, string> } }>
  applications: Array<{ candidate_zoho_id: string; job_display_id: string; sub_status_key: string; received_at: string | null;
    status_at: string | null; hired_date: string | null; owner_name: string | null; custom: { zoho: Record<string, string> } }>
  notes: Array<{ candidate_zoho_id: string; job_display_id: string; seq: number; occurred_at: string | null;
    kind_label: string; author_name: string; body: string }>
}
```

Rules:
- One candidate per Candidate ID (first row wins for the candidate fields).
- A row with a blank Job Opening ID gives a candidate only.
- `source_key = mapSource(Source)`.
- `received_at = Associated On`, falling back to Candidate Last Activity. `status_at = Status Last Updated`.
- Contact rule per candidate: any `never_contact` → `do_not_contact`. Otherwise any `contact_in_future` or `rejected_hirable` → `contact_later`. The reason is `Zoho: <label>`.
- `custom.zoho` keeps every non-empty column verbatim.
- Ignore the column "Status for this job" (lower-case, column 20).
- A status not in `ZOHO_STATUS_KEY` is a problem, never a guess.

- [ ] **Step 1: Failing tests.**
  - `jobViewStatuses.test.ts`: parse the `insert into public.application_sub_statuses` values of `supabase/migrations/0095_zoho_statuses.sql` and assert that the set of keys equals `new Set(Object.values(ZOHO_STATUS_KEY))` and each label maps to the key with that label.
  - `dates.test.ts`: `parseLocalMinute('2023-02-13 15:38','Europe/Skopje') === '2023-02-13T14:38:00.000Z'`, and `parseLocalMinute('', …) === null`.
  - `jobView.test.ts` on the fixture:
    - 6 rows → expected counts
    - a `NEVER to be contacted again` row plus a `Contact in Future` row for the same candidate → `do_not_contact`
    - a `Not contacted` row → `not_contacted`
    - a no-job row → candidate with no application
    - `splitNotesLog` of a two-entry log → 2 notes, newest first, with their authors
    - an unknown status → 1 problem
- [ ] **Step 2:** Run `cd server && npx vitest run src/zohoRecruit`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `server/scripts/zoho-job-view-extract.ts <csv> --tz Europe/Skopje --out .zoho-job-view.json` prints counts, the by-status table and problems. It prints refs only (Candidate ID), never names. It exits 1 on any problem.
  - Add the npm script `"import:zoho-job-view:extract"`.
  - Add `file/` and `.zoho-job-view*.json` to `.gitignore`.
- [ ] **Step 4: Run the extractor on the real CSV:** `cd server && npm run import:zoho-job-view:extract -- "/Users/naum/Downloads/Zoho_Recruit_Candidate_Job_View_V4 - statuses updated - primerok za Naum(Candidate-Job View).csv"`. Expected:
  - 0 problems
  - 3,612 candidates
  - 4,157 applications (± the no-job rows, so report the exact number)
  - notes > 892
  - the by-status counts match `cut -f18` of the CSV, with "Not contacted" and "Not Contacted" summed
- [ ] **Step 5: Commit** `feat: extract the Zoho Candidate-Job View into an import payload` (no data files).

### Task 10: Import function — `import_zoho_job_view`

**Files:**
- Modify: `supabase/migrations/0097_hiring_summary_and_import.sql` (append)
- Create: `scripts/zoho-job-view-import.sh`
- Modify: `supabase/tests/smoke.sql` (blocks `0097-a`…`0097-d`)

**Interfaces:**
- `public.import_zoho_job_view(p_payload jsonb, p_commit boolean default false) returns jsonb`: platform admins only (`platform_admins`, as 0067).
- It returns `{ committed, candidates, applications, notes, by_status: {key: n}, contact_rules: {do_not_contact, contact_later}, refused: [{ref, reason}], unmatched_people: [name] }`.
- With refused > 0 and `p_commit`, it raises `Import refused: % rows have problems.` (the 0067 pattern).
- **Writes:**
  - Candidates: `provider='zoho_recruit'`, `provider_ref=zoho_id`, upsert-skip on `candidates_provider_dedupe`.
  - Applications: job by `custom.zoho.display_id`, `stage_key` = the status's stage, `sub_status_key`, `received_at`, `owner_id` = `people.id` where `lower(btrim(full_name)) = lower(btrim(owner_name))`, `source_provider='zoho_recruit'`, `provider_ref=candidate_zoho_id||':'||job_display_id`, dedupe on `applications_provider_dedupe`, `custom`.
  - Notes: `candidate_notes` with `company_id` = the job's company, `kind='note'`, `actor_name=author_name`, `actor_id` by the same name match, `occurred_at`, `provider='zoho_recruit'`, `provider_ref=candidate_zoho_id||':'||job_display_id||':'||seq`, and `custom.zoho = {job_display_id, kind_label}`.
  - Contact rules on candidates.
- **During the import** `set_config('app.bulk_import','on',true)`. `app.notify_application_owner` returns early when it is on, the `audit` trigger skips row logging when it is on, and `app.applications_fill_job` (0090/0096) returns early when it is on. Zoho's data is the truth, so importing the 59 hires must neither change a job's status nor close-mark anyone. One summary `activity_log` row (`entity_type='imports'`, `action='zoho_job_view'`, `after` = the counts) is written at the end.
- `scripts/zoho-job-view-import.sh --dry-run|--commit [.zoho-job-view.json]` is modelled on `scripts/zoho-import.sh`: it uses the admin JWT impersonation and prints counts only.

- [ ] **Step 1: Failing smoke blocks.**
  - **0097-a:** a 3-candidate payload dry-run → `committed=false` and 0 rows written.
  - **0097-b:** commit → counts match, an `offer_made` row is in stage `offer`, a `do_not_contact` candidate has `do_not_contact=true` and reason `Zoho: NEVER to be contacted again`, 0 `notifications` rows were added, and a `hired` row on a job with headcount 1 leaves that job's `status` and the other applications' `closed_at` unchanged.
  - **0097-c:** an unknown job display id → `refused` names it, and commit raises.
  - **0097-d:** committing the same payload again → `candidates=0, applications=0, notes=0`.
- [ ] **Step 2:** Run `local-verify.sh`. Expected: FAIL in 0097-a.
- [ ] **Step 3: Implement** the function, the trigger guards and the script.
- [ ] **Step 4:** Re-run. Expected: all blocks pass.
- [ ] **Step 5: Commit** `feat: import the Zoho Candidate-Job View on Zoho statuses (migration 0097, part 2)`.

### Task 11: Re-attach the CVs from the backup

**Files:**
- Create: `server/scripts/restore-candidate-files.ts`, `server/src/zohoRecruit/restoreFiles.ts`
- Test: `server/src/zohoRecruit/restoreFiles.test.ts`

**Interfaces:**
- `planRestore(oldCandidates: CsvRow[], oldFiles: CsvRow[], newIdByRef: ReadonlyMap<string, string>): { uploads: Array<{ fileId: string; from: string; to: string; row: Record<string, unknown> }>; skipped: Array<{ fileId: string; reason: string }> }`
  - Old candidate id → `provider_ref` comes from `db/candidates.csv` of the backup.
  - `to = candidate/<newCandidateId>/<fileId>.<ext of old storage_path>`
  - `from = <backup>/files/<old storage_path>`
  - `row` = the old `candidate_files` columns with `candidate_id`/`storage_path` replaced and the same `id`.
  - A candidate with no `provider_ref`, or no longer present, is skipped with a reason.
- Script `npx tsx server/scripts/restore-candidate-files.ts --dry-run|--commit <backupDir>`:
  - loads the new ids with one paged `select id, provider_ref from candidates where provider='zoho_recruit'`
  - uploads with concurrency 4, then inserts the row
  - is idempotent: it skips a file id already in `candidate_files`
  - prints counts and failures by file id, never names

- [ ] **Step 1: Failing tests.** For `planRestore` on 3 synthetic rows: 1 mapped, 1 whose candidate has no `provider_ref` (skipped "manual candidate"), and 1 whose ref isn't re-imported (skipped "not re-imported").
- [ ] **Step 2:** Run `cd server && npx vitest run src/zohoRecruit/restoreFiles.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run again. Expected: PASS.
- [ ] **Step 5: Commit** `feat: re-attach candidate files from the 2026-11-05 backup`.

### Task 12: Release to production (only after the user approves)

- [ ] **Step 1: Pre-flight.**
  - `git log origin/main -3` matches local `main`'s base.
  - Full local gate: `./supabase/tests/local-verify.sh`, `cd app && npm test && npm run typecheck && npm run build`, `cd server && npm test`.
- [ ] **Step 2: Apply 0095, then 0096, then 0097 to prod,** one at a time: `psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/<file>`.
- [ ] **Step 3: Verify the vocabulary.** `select count(*) from application_sub_statuses` = 37, and the Task 2 Step 1 query returns 0 rows.
- [ ] **Step 4: Import.** Run `scripts/zoho-job-view-import.sh --dry-run` and check that the counts and by-status equal Task 9 Step 4, with refused 0 and `unmatched_people` reported to the user. Then run `--commit`.
- [ ] **Step 5: CVs.** Run `npx tsx server/scripts/restore-candidate-files.ts --dry-run ~/Downloads/peopleos-backup-2026-11-05`, then `--commit`. Expected: about 2,706 uploaded (the 4 manual candidates' files skipped), 0 failures.
- [ ] **Step 6: Verify on prod.**
  - Per-status counts in `applications` equal the CSV.
  - `select count(*) from notifications where created_at > now() - interval '1 hour'` is unchanged.
  - Storage `candidate-files` holds about 290 MB.
- [ ] **Step 7: Commit any release notes and push `main`.**
- [ ] **Step 8: Report to the user.** Give counts and unmatched names, and ask them to check the Supabase Usage page over the next days.

---

## Self-review notes

- **Spec coverage:**
  - stages/statuses → T1
  - outcome/in_play → T1, T2, T5
  - status moves stage → T2, T6
  - closure mark → T1, T2, T6
  - delete all old statuses → T1
  - import from CSV, jobs untouched, owner, contact rules, notes → T9, T10
  - CVs → T11
  - egress (Home, lists, notifications, lookups, files, imports in SQL) → T7, T8, T10
  - personal data in git → T9 (.gitignore)
  - release → T12
- **Proportion:** functions are named with signatures and messages, and bodies are left to the builder, starting from each function's live definition.
