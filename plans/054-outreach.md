# 054 — Outreach: sub-statuses inside New and Screening (migration 0069)

The seam plan 052 §5 left. After the Zoho import, 8 open jobs carry hundreds of
sourced applications at `new` that nobody has contacted, and 839 more sit at
`screening` as "Contacted" with no way to say whether the person answered. The
blueprint keeps the seven stages ("any additional stage must have an
operational purpose"), so outreach lives *inside* `new` and `screening` as a
sub-status, logged as an event, counted where attention is counted.

## Decisions (defaults the plan implements; the maintainer says otherwise)

- **D1 Vocabulary** — a lookup `application_sub_statuses`, seeded:
  `new`: `applied` "Applied" (they came to us), `sourced` "Sourced — not yet
  contacted", `contact_attempted` "Contact attempted — no answer yet";
  `screening`: `contacted` "In conversation", `interested` "Interested",
  `awaiting_evaluation` "Awaiting evaluation", `qualified` "Qualified — ready
  for interview". No sub-statuses for the other stages (null).
- **D2 Defaults** — on insert at `new`: `sourced` when the application's
  `source_key` is one of `head_hunt`, `linkedin_profile`, `imported`, else
  `applied`. On a stage change: a sub-status that does not belong to the new
  stage is replaced by the new stage's first sub-status by `sort_order`
  (`contacted` for `screening`), or null where the stage has none. Set by
  trigger, so every write path (the app's client-side stage moves, the RPCs,
  the careers site, the import) gets it without change.
- **D3 Not responding** — derived, never stored: an open application on a
  live job (`jobs.status in ('ready','open','on_hold')`) whose sub-status is
  `sourced`, `contact_attempted` or `contacted` and whose last activity
  (`max(application_events.created_at)`, else `received_at`) is older than
  **30 days**. Shown as a badge, a filter and an attention count. The
  withdrawal reason "No response" (already mapped from Zoho) is what HR picks
  when they give up.
- **D4 One RPC** — `log_outreach(p_application_ids uuid[], p_sub_status_key
  text, p_note text)` records the same outreach on one or many applications:
  an `outreach` event per application plus the sub-status update. Single
  row and bulk use the same call.
- **D5 Backfill** — imported rows map `custom->'zoho'->>'status'`:
  Associated / New → `sourced`; Attempted to Contact / Not Contacted / Not
  contacted → `contact_attempted`; Contacted → `contacted`; Interested →
  `interested`; Waiting-for-Evaluation → `awaiting_evaluation`; Qualified →
  `qualified`. Every other application at `new` / `screening` gets D2's
  default from its `source_key` / stage. Other stages stay null. No events are
  written by the backfill.
- **D6 Where it shows** — the job's Applications tab (badge, filter, bulk log),
  the application page (badge + "Log outreach"), the hiring Applicants panel
  (badge), Reports → attention tile "Not responding", Home's pipeline card one
  line. Nothing on the candidate record (it is per application).

## 1. Migration `supabase/migrations/0069_outreach.sql`

Order: lookup → column → trigger → backfill → events CHECK + columns → RPC →
report → grants. Header comment in the 0067 style.

- `create table public.application_sub_statuses (key text primary key,
  stage_key text not null references public.application_stages(key), label
  text not null, sort_order int not null default 0, archived_at
  timestamptz)`; RLS enabled, `select` to `authenticated` (a lookup, like
  `candidate_sources`), `all` to `service_role`. Seed per D1 with
  `sort_order` 10/20/30 (`new`: applied 10, sourced 20, contact_attempted 30;
  `screening`: contacted 10, interested 20, awaiting_evaluation 30, qualified
  40).
- `alter table public.applications add column sub_status_key text references
  public.application_sub_statuses(key)`; index
  `applications_sub_status_idx on (company_id, sub_status_key) where
  sub_status_key is not null`.
- `app.default_sub_status(p_stage text, p_source_key text) returns text`
  (immutable-ish `stable`, `security definer`, revoked from public): `new` →
  `sourced` when `p_source_key in ('head_hunt','linkedin_profile','imported')`
  else `applied`; otherwise the stage's first unarchived sub-status by
  `sort_order` (null when none).
- Trigger `t3_sub_status before insert or update of stage_key,
  sub_status_key on public.applications` (`app.applications_sub_status()`):
  on insert, `new.sub_status_key := coalesce(new.sub_status_key,
  app.default_sub_status(new.stage_key, new.source_key))`; on update, when
  `stage_key` changed or `sub_status_key` changed, if `sub_status_key` is not
  null and not `exists (select 1 from application_sub_statuses s where s.key
  = new.sub_status_key and s.stage_key = new.stage_key and s.archived_at is
  null)` then — when the *stage* changed, replace it by the default; when only
  the sub-status changed, `raise exception '"<key>" is not a sub-status of
  the <stage> stage.' using errcode = '22023'`. The name `t3_…` sorts after
  `t0_guard_contact` (0067) and before `t8_touch_candidate`; keep the 0067
  naming note.
- Backfill per D5 in one `update … set sub_status_key = case …` over
  applications where `stage_key in ('new','screening')`, using
  `coalesce(custom->'zoho'->>'status', '')`, falling through to
  `app.default_sub_status(stage_key, source_key)`. Runs before the trigger
  exists (the 0067 discipline) so nothing else fires.
- `application_events`: `alter table … drop constraint <the kind check —
  read its name from 0003 / pg_constraint>`, add `check (kind in
  ('stage_change','note','interview_feedback','outreach'))`; `add column
  from_sub_status_key text, add column to_sub_status_key text` (no FK — history
  outlives a retired key). The `audit` trigger on events, if any, is untouched.
- `public.log_outreach(p_application_ids uuid[], p_sub_status_key text,
  p_note text) returns jsonb` — `security definer`, `set search_path =
  public`, `auth.uid()` required ("Sign in first."). For every id: the
  application must exist and be visible (`app.can_view_candidate` on its
  candidate or the reviewer rule — use `app.has_capability(a.company_id,
  'candidates.review')`; refuse with `'You need "Record interview feedback"
  in <company> to log outreach.'`); its stage must be `new` or `screening`
  (`'<name> is at <stage> — outreach is logged at New or Screening.'`); the
  key must belong to that stage (the trigger's sentence). `p_note` trimmed, ≤
  2,000 chars, may be empty. Per application: `insert into application_events
  (application_id, actor_id, kind, body, from_sub_status_key,
  to_sub_status_key) values (…, app.current_person_id(), 'outreach',
  nullif(note,''), old key, p_sub_status_key)` then `update applications set
  sub_status_key = p_sub_status_key` (the touch trigger keeps `updated_at`;
  0067's `t8_touch_candidate` on events bumps `candidates.last_activity_at`).
  All-or-nothing (one transaction; the first refusal aborts with its
  sentence). Returns `{ "logged": n }`. Grant execute to `authenticated`.
  `app.current_person_id()` — reuse whatever 0067 uses to resolve the actor
  (read `record_kudos` / `upsert_sourced_candidate` for the idiom).
- `recruitment_report` (0067's body copied verbatim; only `v_attention`
  changes): `attention` gains `'not_responding'` — count per D3 over the
  company's applications; keep the three existing keys unchanged.
- `app.not_responding(a public.applications) returns boolean` — the D3 rule
  as one `stable` function (`security definer`, revoked from public, used by
  the report; the app mirrors it in the lib for badges — see §3).

## 2. Smoke — `supabase/tests/smoke.sql`, a `0069` block before the final line

Fixtures: the 0067 block's pool holder Ada, Company B's open jobs and the
seeded people (read the 0067 / 0068 blocks for names). Asserts (real
`assert`s in `do $$` blocks):
1. Seed rows: 7 sub-statuses, the stage of each, nothing for `interview`.
2. Insert defaults: an application via `upsert_sourced_candidate` with
   `source_key 'head_hunt'` is `sourced`; one with `'careers_page'` is
   `applied`; a careers-site style insert without `source_key` is `applied`.
3. Stage move `new → screening` (a plain `update`, as the app does) turns
   `sourced` into `contacted`; `screening → interview` turns it null;
   `interview → screening` (a plain update) gives `contacted` again.
4. A direct `update … set sub_status_key = 'qualified'` on a `new`
   application raises `"qualified" is not a sub-status of the new stage.`;
   `'contact_attempted'` on a `new` application succeeds.
5. `log_outreach` as Ada on two `new` applications with `'contact_attempted'`
   and a note: `{ "logged": 2 }`, two `outreach` events with `from 'sourced'
   / to 'contact_attempted'` and the note, the rows updated; the candidates'
   `last_activity_at` moved.
6. Refusals: a third id at `interview` in the same call → the interview
   sentence and **no** event written for the first two (atomic); a key of
   the wrong stage → the trigger sentence; a person without
   `candidates.review` in that company (Omar, per the 0028 fixture rule) →
   the capability sentence; signed out → "Sign in first.".
7. Backfill: two applications seeded before the block with
   `custom.zoho.status` "Associated" and "Interested" at `new` /
   `screening` — after the migration they read `sourced` / `interested`
   (seed them in the 0067 block's style **before** the 0069 migration runs —
   i.e. the smoke's fixtures for this item must be created by an earlier
   block; if that is impractical, assert the CASE mapping by calling the
   backfill expression as a `select` over the same values).
8. `not_responding`: an application at `screening/contacted` with its only
   event 31 days old on an open job → `true`; the same with an event today →
   `false`; at `interested` → `false`; on a `closed` job → `false`.
   `recruitment_report(B, …).attention->>'not_responding'` = 1 with that
   fixture.

`PATH="/c/Program Files/PostgreSQL/18/bin:$PATH" bash supabase/tests/local-verify.sh`
must end `SMOKE TESTS PASSED` (69 migrations).

## 3. App

- **`database.ts`** (hand-maintained): table block `application_sub_statuses`
  (Row `archived_at, key, label, sort_order, stage_key`; relationship
  `application_sub_statuses_stage_key_fkey`), `applications.sub_status_key:
  string | null` (+ `applications_sub_status_key_fkey`),
  `application_events.from_sub_status_key / to_sub_status_key: string | null`;
  Functions `log_outreach: { Args: { p_application_ids: string[];
  p_note: string; p_sub_status_key: string }; Returns: Json }`.
- **`lib/outreach.ts`** (vitest beside it): `SUB_STATUS_STAGES = ['new',
  'screening']`; `type SubStatus = { key; stage_key; label; sort_order }`;
  `subStatusesFor(all, stageKey)` (unarchived, sorted); `NOT_RESPONDING_DAYS =
  30`; `notResponding({ stage_key, sub_status_key, last_activity_at |
  received_at, job_status }, today)` — the D3 rule, `today` = `todayDb()`;
  `outreachBadge(app)` → `''` / `Not responding` (amber) — the sub-status
  label itself renders from the lookup; `outreachLine(event)` → "Outreach:
  <from label or —> → <to label> · <note>" for the timeline;
  `OUTREACH_BLOCKED = 'Outreach is logged at New or Screening.'`.
- **`components/OutreachDialog.vue`** (`outreach-dialog`): props `{
  applications: { id; full_name; stage_key; sub_status_key }[]; subStatuses:
  SubStatus[] }`; eyebrow *Outreach*, title "Log outreach for <name>." /
  "Log outreach for <n> applications."; radios of the stage's sub-statuses
  (`outreach-sub-<key>`; when the selection spans both stages, only the
  sub-statuses of the stage they all share are offered — mixed stages show
  "Pick applications at the same stage." and disable Save); textarea
  `outreach-note` "What happened? (optional)"; Save (`outreach-save`) →
  `supabase.rpc('log_outreach', …)`; refusals verbatim; emits `logged(n)`.
- **`JobPage.vue` Applications tab**: each row's stage badge gains, for `new`
  / `screening`, a second badge with the sub-status label (`sub-badge`,
  grey; `Not responding` amber when `notResponding`); a **filter row** above
  the list: sub-status select ("Any sub-status" + the seven, grouped by
  stage) and a checkbox "Not responding only" (`filter-not-responding`); a
  **checkbox per row** (`select-app-<id>`, only `new` / `screening` rows) and
  a **Log outreach** button (`log-outreach`, enabled when ≥ 1 selected) that
  opens `OutreachDialog`; after `logged`, reload rows. Row action **Log
  outreach** (`log-outreach-<id>`) for single rows beside *Move to
  screening*. `loadApplications` adds `sub_status_key` and loads
  `application_sub_statuses` once (unarchived). `last_activity_at` for the
  badge: add `events:application_events(created_at)` ordered desc limit 1 —
  or, cheaper, select `max` via a second query keyed by id; pick the one that
  keeps the page under two round trips and say which.
- **`ApplicationPage.vue`**: the sub-status badge beside the stage badge; a
  **Log outreach** button in the review actions (`new` / `screening` only);
  the timeline renders `outreach` events with `outreachLine` and the label
  "Outreach"; the stage-change save path is unchanged (the trigger sets the
  default).
- **`hiring/ApplicantsPanel.vue`**: the sub-status label under the stage cell
  (`<small class="sub">`) and the *Not responding* badge; the stage filter
  gains "Not responding" as a pseudo-value (client-side over the loaded
  rows).
- **`ReportsPage.vue`**: a fourth attention tile `{ label: 'Not responding',
  value: a.not_responding, hint: 'Sourced or contacted, no activity in 30
  days.' }`.
- **`home/RecruitmentSnapshot.vue`**: one line under the pipeline card when
  the viewer sees the pipeline: "<n> not responding for 30 days" — computed
  client-side with `notResponding` over the loaded applications (Home already
  loads them with the job status); absent when 0 (never a zero).
- **`server/src/zohoRecruit/mapping.ts`**: `StatusMapping` gains `sub?:
  string` for the D5 statuses; `payload.ts` passes `sub_status_key` on the
  application row; `import_zoho_recruit` is **not** changed (the backfill
  covered the imported rows; a re-run skips them) — a comment in payload.ts
  says the key is carried for the next import, not read by 0067. Server
  tests for the mapping.
- Gating (hints; RLS and the RPC decide): the outreach buttons render when
  `auth.can(company_id, 'candidates.review')` — the same `canReview` the
  pages already compute.

## 4. E2E — `app/e2e/outreach.spec.ts` (live, `E2E` prefixes, cleanup both ends)

Seed (service client): one open SNOW job "E2E Outreach Role", three
candidates + applications at `new` with `source_key 'head_hunt'` (→
`sourced` by the trigger), one more at `screening` whose only event is 31 days
old (insert the event with `created_at` back-dated) → admin → job Applications
tab → the three rows show *Sourced — not yet contacted*, the fourth *In
conversation* + *Not responding* → tick two → Log outreach → *Contact
attempted — no answer yet*, note "E2E: left a voicemail" → the two badges
change; DB: two `outreach` events with the note, `sub_status_key` updated →
"Not responding only" shows the fourth row alone → open it → the timeline
shows the outreach entry after logging *Interested* from the page → Reports
(SNOW) attention shows *Not responding* = 0 after that (the fresh event) →
move a `sourced` row to screening → its badge reads *In conversation*.
Then run `hiring-pipeline`, `job-workspace`, `candidate-review`, `reports`,
`home-dashboard`, `talent-pool` (a stage badge change touches shared rows).

## 5. Docs

`docs/data-model.md`: the recruitment section gets a paragraph on
sub-statuses (lookup, trigger defaults, `outreach` events, "not responding"
derived) and `application_sub_statuses` in the table list. `plans/README.md`
row 054; `docs/development-plan.md` Done row + "Later, per blueprint" drops the
outreach item; `docs/session-handoff.yaml` `state.live_db` 0001–0069, the
next-slice pointer.

## Out of scope

Automated reminders / emails to candidates; sequences; a sub-status on any
other stage; per-company vocabularies (one holding list; `archived_at` is the
retirement path); Zoho re-import of statuses (the backfill did it once).
