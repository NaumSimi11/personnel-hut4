# 068 — Statuses on every stage (migration 0088)

Status: implemented, migration 0088 not yet applied to the live database.

## Why

Plan 054 gave New and Screening a sub-status and kept the other five stages
bare. HR asked for her own statuses on every stage: add one from Hiring →
Labels and use it straight away, and tidy the ~3,300 old closed
applications with them. The lookup (`application_sub_statuses`) already
allowed any stage and admin writes; what held the line was the seed,
`log_outreach` (New and Screening only) and the app.

## Decisions (made 2026-10-08; the maintainer said "go")

- **D1 Every stage.** All seven stages may carry statuses. No new stages.
- **D2 Seed from what is there.** Rejected (8) and Withdrawn (7): the
  reasons already on the rows, word for word. Interview (13), Offer (2),
  Hired (3): Zoho Recruit's statuses, lightly cleaned. 33 rows.
- **D3 Backfill** (`app.backfill_sub_statuses()`, rerunnable): Rejected
  and Withdrawn by their reason (a fixed reason → key map, so a renamed
  label does not break a later run), else by the Zoho status, else — for a
  withdrawal by an earlier `close_jobs` — "Job closed"; Interview, Offer and
  Hired by the Zoho status; stage-guarded, a row with a status keeps it, a
  row nothing maps is not touched, and the count is what was labelled.
  Audit and `updated_at` triggers off for the sweep. `scripts/zoho-import.sh
  --commit` runs it after the import. Live preview (2026-10-08): 3,314 of
  3,374 rows labelled; the 60 Hired rows stay blank (Zoho says only
  "Hired").
- **D4 Defaults.** New by source and Screening by first status, as before.
  Interview onwards start blank until somebody picks. `applied`, `sourced`,
  `contact_attempted` and `contacted` are named by the rules (New's defaults,
  "not responding"), so they can be renamed but not retired — a CHECK, and
  no Retire button.
- **D5 One door.** `set_application_status(ids, key, note)`: any stage,
  closed ones included, `candidates.review`, all or nothing. The event is
  `outreach` at New and Screening (so "not responding" reads it as before)
  and the new kind `status_change` elsewhere. On Rejected and Withdrawn the
  stored reason follows the status when it was only the old status's name
  (or empty); a reason in somebody's own words stays. `log_outreach` is left
  as it was for the build already deployed.
- **D6 Reject and Withdraw** pick a status of the stage arrived at (required
  while it has any) plus an optional note; the reason stored is the note,
  else the status. The screening hand-off's Reject and the job page's
  per-row Reject do the same. `close_jobs` withdraws to "Job closed".
  Picking "Do not contact" shows that it only labels the application; the
  block on sourcing and re-applying is still the candidate's contact rule.
- **D7 Labels.** Add (key made from the first name, never reused), rename,
  retire, restore. One live name per stage (case and space ignored), also
  as a unique index. No hard delete, no reordering.
- **D8 Where it shows.** The badge at every stage, retired statuses marked;
  "Set status" on the application page and every row of a job's
  Applications tab (bulk there too); a status filter on the job tab and on
  Hiring → Applicants (applied in the query, narrowed to the chosen stage).

Not included: new stages, reports by status, a status picker on Confirm
hire, the server's Zoho map (`mapping.ts`) carrying the new keys, and
"Do not contact" setting the candidate's contact rule by itself (open
product question).

## What changed

- `supabase/migrations/0088_statuses_on_every_stage.sql`, smoke block
  `0088` in `supabase/tests/smoke.sql` (and the 0069 / 0071 assertions that
  encoded "only New and Screening").
- `app/src/lib/stageStatuses.ts` (all-stage shaping), `hiringLabels.ts`
  (keys, duplicates, groups with retired rows), `LabelsPanel.vue`,
  `StatusDialog.vue` (was `OutreachDialog.vue`), `RejectApplicationDialog.vue`,
  `CandidateHandoffDialog.vue`, `ApplicationPage.vue`, `JobPage.vue`,
  `ApplicantsPanel.vue`, `types/database.ts`; `scripts/zoho-import.sh`.
- E2E: `hiring-labels.spec.ts` adds → retires → restores; `outreach.spec.ts`
  wording.

## Rollout

Apply 0088 first (`psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f
supabase/migrations/0088_statuses_on_every_stage.sql`, one transaction),
then push `main`. The deployed build keeps working in between: it calls
`log_outreach`, which is unchanged.
