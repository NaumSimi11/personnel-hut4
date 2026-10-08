# 070 — A job fills itself (migration 0090)

Status: implemented 2026-10-08.

## Why

HR's note: "When we are closing job, by someone hired it should automatically
be closed." The job page said "Hired — close the job once the headcount is
met", and nothing ever did. Two live jobs sat Open at 1 / 1.

## Decisions (maintainer, 2026-10-08)

- **D1 Filled, automatically.** The hire that meets the headcount moves a
  ready / open / on-hold job to `filled` — the existing "closed because we
  hired" status, kept apart from `closed` (abandoned) in the reports. A
  trigger on the stage moving *to* hired, so every hire path counts and an
  imported row inserted at hired does not; a closed job is never touched.
- **D2 Headcount** = the hiring request's, else Zoho's
  (`custom->'zoho'->>'headcount'`: all 75 jobs are Zoho's, none has a
  request, ten want 2–5), else 1. `app.job_headcount` and `lib/headcount.ts`
  read it the same way; the job page's "Hired x / y" and the openings list
  use it.
- **D3 The others are left alone.** A filled job says how many are still in
  play; "Withdraw the rest" (`withdraw_in_play`) withdraws them all as
  "Job closed", reason "Position filled.", after a confirmation that names
  any offer still out. The job stays filled.
- **D4 Future hires only.** The two jobs already at 1 / 1 stay as they are.
- **D5 Status picker.** The job's fixed status buttons became a picker of
  every other status (back or on — a filled job reopened, a closed one
  revived); Ready still waits for a description.

## What changed

- `supabase/migrations/0090_fill_job_on_hire.sql`; smoke block `0090` (and
  the Company A fixture job now wants two hires so the report blocks still
  see an open role).
- `app/src/lib/headcount.ts`, `jobWorkspace.ts` (`jobStatusOptions`,
  `filledNote`), `hiringTabs.ts`, `pages/JobPage.vue`,
  `components/hiring/JobOpeningsPanel.vue`, `types/database.ts`; E2E
  `job-workspace.spec.ts` uses the picker.
