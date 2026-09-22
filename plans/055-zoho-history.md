# 055 — Candidate notes, and the Zoho interviews and reviews (migration 0070)

The two seams plan 052 §5 left: the candidate-level Zoho notes (counted, not
imported) and the Zoho interviews / reviews (ids preserved, rows not
created). After this slice a recruiter opening an imported candidate sees
the calls, messages and notes that were about the person, and an imported
application shows its interviews and the reviewers' verdicts the way a
Personnel interview does.

## What the export holds (profiled 2026-09-22, `docs/Data_001/Data/`)

- Notes: 3,006. Candidates module 2,936, of which 1,212 were attached to an
  application by 052. Left: **1,557 job-less + 199 whose job pair is no
  association** (those 199 jobs are not in the export at all) = **1,756
  person-level notes**. Types: Notes 1,032 · Call 495 · Unassociation 103 ·
  Change Status 32 · Association 26 · LinkedIn Msgs (dated types) ~50 ·
  General Review 10 · Meeting 4 · Others 2 · TASK 2. Bodies: p50 65 chars,
  max 2,627. Interviews-module 34 / Job Openings 34 / Tasks 2 stay skipped
  (counted).
- Interviews: 104; **99** have a (candidate, job) pair that is an imported
  application. Names: Level 1 (63), Level 2 (14), Phone (12), Online (10),
  General (4), Live Video (1). Interviewer(s): Zoho user ids, 52 rows with
  more than one, 11 distinct users. From/To `MM/DD/YYYY hh:mm AM/PM` in
  Europe/Skopje. Interview Status is an *outcome* (Move to next round 21,
  Rejected 14, On-Hold 6, Shortlist 5, Hired 5, Wait-list 3, Strong Reject 3,
  Cancelled 3, blank 44). Feedback on 17, Schedule Comments on 3, Location on
  16.
- Reviews: 75, all "Reviewed"; Rating 1–4 (4: 34 · 3: 13 · 2: 20 · 1: 8);
  Source Interviewer Review 57 / Recruiter Review 18; comments on 27; **57
  reference an exported interview**; 60 distinct (interview, creator) pairs.
  Reviews_Asssessment: 37 question/answer rows for 5 reviews (Score always
  0; the answers are free text).
- Users: 25 (052 resolved 7 to people; 18 unresolved — kept by name).

## Decisions (defaults the plan implements; the maintainer says otherwise)

- **D1 Notes are person-level.** `candidate_notes` per 052 §5 with
  `company_id` nullable; every imported note has `company_id null` (nothing
  ties them to a company that exists). Visible to pool holders
  (`app.can_source_candidates()`), and to `candidates.view` holders in the
  tagged company when `company_id` is set. A pool holder may add a note from
  the record (`add_candidate_note`); an author or an admin may delete their
  note. No edit (history).
- **D2 Note kinds** — a lookup is overkill for history: `kind text` from a
  CHECK list `note, call, message, meeting, status_change, association,
  unassociation, review, task, other`; the Zoho type maps: Notes → note,
  Call → call, `LinkedIn Msgs *` → message, Meeting → meeting, Change Status
  → status_change, Association / Unassociation → themselves, General Review →
  review, TASK → task, Others → other. The verbatim Zoho type is kept in
  `custom.zoho.type`. Bodies carry the 052 prefix `[Zoho <Type> · <DD Mon
  YYYY> · <actor>] ` only when the actor could not be linked; otherwise the
  row's own `actor_id` / `occurred_at` carry it.
- **D3 Interviews** import as `interviews` rows on the matched application:
  `kind` = `phone` when the Zoho name contains "Phone", else `other` (the
  name is kept in `custom.zoho.name` and shown); `scheduled_at` = From;
  `duration_minutes` = To − From clamped 15..480, default 60; `location`;
  `status` = `cancelled` for Cancelled, else `completed` (every row is in the
  past); `notes` = "Feedback: …" and "Schedule comments: …" when present;
  `created_by` = the resolved owner or null; the outcome in
  `custom.zoho.outcome`; the resolved interviewers become `interview_panel`
  rows, unresolved names go to `custom.zoho.interviewers`. Cancellation
  Reason → `custom.zoho.cancellation_reason`. The 5 unmatched interviews are
  counted, not created. Schema: `interviews` gains `provider`, `provider_ref`,
  `custom jsonb`.
- **D4 Reviews** import as `scorecards` on the matched interview: Zoho's
  1–4 rating is our 1–4 scale — `ratings = [{ criterion_id: 'zoho_overall',
  label: 'Overall (Zoho Recruit)', rating: <1..4>, evidence: <comments or
  ''> }]`; `recommendation` 4 → `strong_yes`, 3 → `yes`, 2 → `no`, 1 →
  `strong_no`; `summary` = the comments plus, for the 5 reviews with
  assessment answers, "Q: … — A: …" lines; `submitted_at` = Created Time;
  `author_id` = the resolved creator or **null** with `author_name` set
  (schema: `author_id` becomes nullable, `author_name text` added, `provider`,
  `provider_ref`). Reviews whose interview was not created (18) or whose
  (interview, author) already has a scorecard (duplicates) are counted, not
  created. Source ("Interviewer Review" / "Recruiter Review") →
  `custom`-less table, so it goes into the label of the ratings entry:
  `Overall (Zoho Recruit · Recruiter Review)`.
- **D5 One import function, one shell mode.** `import_zoho_history(p_payload
  jsonb, p_commit boolean)` (0070) in the 0067 style: pass 1 validates and
  resolves (users, candidates by `provider_ref`, applications by (candidate,
  job) refs, interviews by ref), pass 2 writes; `p_commit false` reports
  only; idempotent by `(provider, provider_ref)` unique partial indexes on
  the three tables. The extract gains `--history .zoho-history.json`; the
  shell gains `scripts/zoho-import.sh --dry-run|--commit --history`.
- **D6 Where it shows.** Candidate record: a **Notes** card (list newest
  first, kind badge, actor, date; add for pool holders; remove own).
  Application page and job Interviews panel: imported interviews render as
  today with a line "Imported from Zoho Recruit · <Zoho name> · outcome: <…>"
  and the panel names; scorecards show `author.full_name ?? author_name`.
  Nothing on Home or Reports.

## 1. Migration `supabase/migrations/0070_zoho_history.sql`

- `candidate_notes (id uuid pk default gen_random_uuid(), candidate_id uuid
  not null references candidates(id) on delete cascade, company_id uuid
  references companies(id), kind text not null default 'note' check (kind in
  (…D2…)), body text not null check (length(body) between 1 and 4000),
  actor_id uuid references people(id), actor_name text, occurred_at
  timestamptz not null default now(), provider text, provider_ref text,
  custom jsonb not null default '{}' check (jsonb_typeof(custom) =
  'object'), created_at timestamptz not null default now())`; indexes
  `(candidate_id, occurred_at desc)`, unique `(provider, provider_ref) where
  provider_ref is not null`; RLS: `sel` = `app.can_source_candidates() or
  (company_id is not null and app.has_capability(company_id,
  'candidates.view'))`; `del` = `actor_id = app.current_person_id() or
  app.is_admin()`; no client insert/update (the RPC and the import write).
  `t8_touch_candidate`-style: an insert bumps `candidates.last_activity_at`
  (reuse 0067's `app.touch_candidate_activity` if its signature allows,
  else a two-line trigger).
- `public.add_candidate_note(p_candidate_id uuid, p_body text) returns
  jsonb` — security definer; "Sign in to continue."; `app.can_source_candidates()`
  else `'You need "Work the talent pool" to add a note to a candidate.'`;
  candidate exists and not archived (`'That candidate is not in the talent
  pool.'` / `'<name> is archived — restore them first.'`); body trimmed,
  1..4000 (`'Write the note first.'` / `'Keep the note to 4,000 characters
  or fewer.'`); inserts `kind 'note'`, `actor_id` = the caller, `company_id
  null`; returns `{ "id": … }`.
- `interviews`: add `provider text`, `provider_ref text`, `custom jsonb not
  null default '{}'` (object check); unique partial index on `(provider,
  provider_ref)`. `scorecards`: `alter column author_id drop not null`, add
  `author_name text`, `provider`, `provider_ref` + the same unique partial
  index; a CHECK `author_id is not null or author_name is not null`. The
  existing `unique (interview_id, author_id)` keeps working (nulls are
  distinct). The RLS policies need no change (a null author never matches
  `app.current_person_id()`; readers fall to the capability branch).
- `public.import_zoho_history(p_payload jsonb, p_commit boolean default
  false) returns jsonb` — platform admin only (the 0067 check); payload
  `{ users: [{zoho_id, email, name}], candidate_notes: [{zoho_id,
  candidate_zoho_id, kind, zoho_type, body, actor_zoho_id, actor_name,
  created_at}], interviews: [{zoho_id, candidate_zoho_id, job_zoho_id, name,
  kind, scheduled_at, duration_minutes, location, status, outcome, notes,
  owner_zoho_id, interviewer_zoho_ids: [], cancellation_reason, created_at}],
  reviews: [{zoho_id, interview_zoho_id, rating, recommendation, comments,
  summary, source, author_zoho_id, created_at}] }`. Pass 1: users → people
  by work email (0067's rule, generic accounts never map); candidates by
  `provider = 'zoho_recruit' and provider_ref = candidate_zoho_id`;
  applications by candidate + job refs (`jobs.provider_ref` / `custom.zoho.id`
  — read 0067 for where the job's Zoho id lives); interviews by ref. Rows
  that cannot resolve are **counted by reason** (`candidate_missing`,
  `application_missing`, `interview_missing`, `duplicate_author`,
  `already_imported`), never refused — the whole call still succeeds; a
  malformed row (missing id, bad date, body too long) is a `problem` and
  refuses the call in the 0067 way. Pass 2 (when `p_commit`): insert
  notes, interviews (+ `interview_panel` for resolved interviewers, `custom`
  with name / outcome / unresolved interviewers / cancellation reason),
  scorecards (skip when `(interview_id, author_id)` exists for a non-null
  author). Report `{ committed, counts: { notes_created, notes_skipped,
  interviews_created, interviews_skipped, panel_rows, scorecards_created,
  scorecards_skipped, users_resolved, users_unresolved }, skipped: [{kind,
  ref, reason}], problems: [] }`. All-or-nothing on commit. Grants:
  execute to `authenticated` (the admin check inside) and `service_role`.
- `app.can_view_candidate` etc. untouched. `database.ts`: `candidate_notes`
  block; `interviews` + `scorecards` new columns; Functions
  `add_candidate_note`, `import_zoho_history`.

## 2. Smoke — a `0070` block before the final line

1. `add_candidate_note` as Ada on a pool candidate → a row with `actor_id`
   Ada, `company_id null`, `last_activity_at` bumped; the refusals (signed
   out; Omar without the pool capability; archived candidate; empty; 4,001
   chars).
2. RLS: Ada (pool) sees the note; Omar (candidates.view in B only) does not
   see a null-company note but sees a company-B note inserted directly;
   Omar cannot delete Ada's note; Ada deletes her own.
3. `import_zoho_history` dry run over a fixture payload: 2 notes (one
   candidate missing → skipped with reason), 2 interviews (one application
   missing → skipped), 2 reviews (one duplicate author → skipped) — counts
   exact, nothing written; commit → rows exist, `interview_panel` has the
   resolved interviewer, the unresolved name sits in `custom.zoho.interviewers`,
   the scorecard with a null author has `author_name`; re-run → everything
   `already_imported`, nothing new.
4. A scorecard insert with both `author_id` and `author_name` null is
   refused by the CHECK.

## 3. Server — `server/src/zohoRecruit/history.ts` (+ tests) and the scripts

- `history.ts`: `buildHistory(ctx)` from the CSVs already parsed by
  `payload.ts` helpers (`csv.ts`, `dates.ts`, the users list): the D2 kind
  map (`noteKind(zohoType)`), the prefix rule, the interview mapping (D3:
  name → kind, From/To → `scheduled_at` / `duration_minutes` in the
  configured tz, status, outcome, interviewer id split on `,` / `;`), the
  review mapping (D4: rating → recommendation, the assessment Q/A into
  `summary`), and counts `{ notes: { imported, skipped_modules,
  already_attached }, interviews: { matched, unmatched }, reviews: {
  matched, unmatched, duplicates } }`. "Already attached" = the 1,212 notes
  052 imported (a note whose (candidate, job) pair IS an association is
  left to 052's path). Tests on the fixtures in `server/src/zohoRecruit/
  fixtures/` (extend `Notes_001.csv`, add `Reviews_001.csv`, `Reviews_
  Asssessment.csv`; `Interviews_001.csv` exists) — kinds, prefix, the tz
  conversion, the clamp, the recommendation map, the unmatched counts.
- `zoho-recruit-extract.ts`: `--history .zoho-history.json` writes the
  payload; prints the counts. `scripts/zoho-import.sh`: a third argument
  `--history` switches the function to `import_zoho_history` and the payload
  default to `.zoho-history.json`; the report printer shows the counts and
  the skipped reasons (grouped, counts only). `server/package.json`:
  `import:zoho-history:extract`.

## 4. App

- `lib/candidateNotes.ts` (+ tests): `NOTE_KINDS` labels (`note` Note,
  `call` Call, `message` Message, `meeting` Meeting, `status_change` Status
  change, `association` Added to a job, `unassociation` Removed from a job,
  `review` Review, `task` Task, `other` Other); `noteActor(n)` → actor's
  `full_name` ?? `actor_name` ?? 'Zoho Recruit'; `noteLine` not needed
  (the card renders fields).
- `components/CandidateNotesCard.vue` (`candidate-notes`): loads
  `candidate_notes` with `actor:people!candidate_notes_actor_id_fkey
  (full_name)`, newest first, 50 then **Show more**; each row
  (`note-<id>`): kind badge, body (pre-wrap), "<actor> · <shortDate>"; a
  `<form>` (pool holders: `auth.isAdmin || auth.canAnywhere('candidates.source')`)
  with textarea `#note-body` (placeholder "What happened? Calls, messages,
  anything about the person — not about one job.") and **Add note**
  (`note-add`) → `add_candidate_note`; **Remove** (`note-remove-<id>`) for
  own notes / admins via `confirmAction` → `candidate_notes.delete()`
  (zero rows → "You do not have permission to remove this note."). Empty:
  "No notes yet."
- `pages/CandidatePage.vue`: the Notes card between Applications and Files.
- `components/ApplicationInterviewsCard.vue` and `JobInterviewsPanel.vue`:
  select adds `provider, custom` (interviews) and `author_name` (scorecards);
  an imported interview shows the line "Imported from Zoho Recruit · <custom
  .zoho.name> · outcome: <custom.zoho.outcome or —>" (`interview-imported`)
  and the unresolved interviewer names after the panel; the scorecard author
  reads `author?.full_name ?? author_name`.
- `lib/interviews.ts`: `interviewImportLine(i)` for that sentence (tested).

## 5. E2E — `app/e2e/candidate-notes.spec.ts`

Seed a pool candidate (`provider 'e2e'`) → admin → the record → Notes card
"No notes yet." → add "E2E: called, voicemail" → the row shows with the
admin's name and today → DB row (`kind 'note'`, `company_id null`,
`actor_id` = the admin's person) → Remove → gone. Then seed an application
with an imported-style interview (`provider 'zoho_recruit'`, `custom.zoho
{ name: 'Level 1 Interview', outcome: 'Move to next round', interviewers:
['E2E Unresolved'] }`, status `completed`) and a scorecard with `author_id
null`, `author_name 'E2E Reviewer'`, rating 4 → the application page shows
the imported line, the unresolved name and "E2E Reviewer" on the scorecard.
Cleanup both ends. Then `interviews-offer`, `candidate-review`,
`talent-pool`, `job-workspace`.

## 6. Live, in order (the controller)

Apply 0070 → `npm --prefix server run import:zoho-history:extract` (counts)
→ `scripts/zoho-import.sh --dry-run --history` (skipped reasons, counts) →
`--commit --history` → re-run the dry run (everything `already_imported`).

## 7. Docs

`docs/data-model.md` (candidate notes: person-level vs company-tagged, who
reads; imported interviews / scorecards, `author_name`), `docs/integrations-
zoho.md` (the history import: what comes in, what is skipped, the three
commands, re-runs skip), `plans/README.md` 055 row, `docs/development-plan.md`
Done row, `docs/session-handoff.yaml`.

## Out of scope

Editing notes; notes on the application page (they are events there);
importing the 34 interview-module notes and the job/task notes; mapping Zoho
outcomes to our stage changes (the applications already carry their final
stage); a lookup for note kinds; assessments as structured ratings.
