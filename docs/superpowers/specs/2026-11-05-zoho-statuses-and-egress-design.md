# Zoho statuses, re-import, and staying under the Supabase Free limits

Date: 2026-11-05 · PeopleOS (`/Users/naum/Downloads/files`) · production = `main`

## Why

HR works in Zoho Recruit's vocabulary. The app's hiring pipeline must use
**Zoho's stages and Zoho's statuses exactly as HR's export has them**. Those
statuses are what the app gets optimised around. On 2026-11-05 every candidate
and all hiring data was wiped from production, so the export can come back in
cleanly on the new model. People (45) and jobs (76) were kept. The backup is in
`~/Downloads/peopleos-backup-2026-11-05/`.

The project runs on the Supabase **Free plan**. Going over a quota there
restricts the whole project, logins included. The app must use little enough
that normal use, with 4,500+ applications, never gets close. Egress (data sent
out of Supabase, 5 GB a month) is the quota at risk. On 2026-11-05 the database
was 58 MB of 500 MB, and storage was about 300 MB of 1 GB before the wipe.
Staying on Free is Claude's assumption. The user did not rule out Pro.

## Goals

1. Stages are Zoho's four, in this order: **Screening → Interview → Offered → Hired**.
2. Statuses are Zoho's 37, each under the stage the export gives it, with
   Zoho's wording (table below).
3. Every status carries a hidden **outcome**: `open`, `rejected`, `withdrew`
   or `hired`. Everything that today asks "is this application finished?" by
   looking at the stage asks the outcome instead.
4. The export is re-imported, with each application on its exact Zoho status.
5. No screen does an unbounded read. Normal daily use of the whole team stays
   far below 5 GB of egress a month.

## Non-goals

- Moving to the Pro plan, or a live Zoho sync.
- Redesigning hiring screens beyond what the new stages and statuses need.
- Bringing back the activity-log history that was wiped.

## Anti-goals (a failure even if it works)

- A status from the export that has no home, or lands under a different stage
  than the file says.
- A rejected or withdrawn candidate counted as open, or a job that stops
  filling itself when its headcount is hired (migration 0090).
- Any page whose load grows with the number of candidates or applications.
- Real personal data in git. The export, `file/*.md` and the backup are never
  committed, and `file/` needs a `.gitignore` entry.

## Source data

Import from
`~/Downloads/Zoho_Recruit_Candidate_Job_View_V4 - statuses updated - primerok za Naum(Candidate-Job View).csv`
(**the UTF-8 one, not "(1)"**, which is cp1252). It is RFC 4180 with 32
columns, 4,567 rows, 3,612 candidates and no ragged rows. One row is one
candidate on one job. A row with an empty Job Opening ID is a candidate with no
application. `file/1–4.md` hold the same rows, but only the first 21 columns,
as TSV split into four parts with a broken row (ZR_599). Use them only to
cross-check.

Columns: Candidate ID, Full Name, Email, Mobile / Phone, LinkedIn, Skill Set,
Source, Candidate Owner, Overall Candidate Status, Overall Candidate Stage,
Tags, Candidate Last Activity, Job Opening ID, Job Title, Job Opening Status,
Hiring Manager, Assigned Recruiter(s), **Status for this Job** (Zoho's status,
the one that counts), Department, Status for this job (an old hand-made slug,
**ignore it**), **Stage for this Job**, Associated On, Status Last Updated,
Hired Date, Hired By, Interviews (count), Last Interview, Review Ratings, Notes
for this Job (count), Latest Job Note Date, Latest Job Note, Job Notes Log
(newest first).

## Stages and statuses (decided)

Stage keys stay `screening`, `interview`, `offer` (label "Offered") and
`hired`. The stages `new`, `rejected` and `withdrawn` go away. Reusing keys is
Claude's call, to keep churn low. Labels are Zoho's text, except that "Not
contacted" and "Not Contacted" merge into one.

| Stage | Status (label = Zoho text) | Outcome | Contact rule set by the import |
|---|---|---|---|
| Screening | New | open | |
| Screening | Associated | open | |
| Screening | Not Contacted | open | |
| Screening | Attempted to Contact | open | |
| Screening | Contacted | open | |
| Screening | Not responding | withdrew | |
| Screening | Interested | open | |
| Screening | Not Interested | withdrew | |
| Screening | Qualified | open | |
| Screening | Waiting-for-Evaluation | open | |
| Screening | Unqualified | rejected | |
| Screening | Rejected-for-Interview | rejected | |
| Screening | Contact in Future | withdrew | contact_later |
| Screening | NEVER to be contacted again | withdrew | do_not_contact |
| Interview | Interview-to-be-Scheduled | open | |
| Interview | Interview-Scheduled | open | |
| Interview | Interview-in-Progress | open | |
| Interview | Interview 1 - HR | open | |
| Interview | Interview 2 - Stakeholders | open | |
| Interview | Interview 3 - Other stakeholder | open | |
| Interview | Interview 4 - Other stakeholders | open | |
| Interview | Task | open | |
| Interview | No-Show | open | |
| Interview | Feedback to be provided from an Interview | open | |
| Interview | Submitted-to-hiring manager | open | |
| Interview | On-Hold | open | |
| Interview | Rejected | rejected | |
| Interview | Rejected by HR | rejected | |
| Interview | Rejected by hiring manager | rejected | |
| Interview | Rejected by Manager - Interview | rejected | |
| Interview | Rejected-Hirable | rejected | contact_later |
| Interview | Withdraw Application | withdrew | |
| Offered | To-be-Offered | open | |
| Offered | Offer-Made | open | |
| Offered | Offer-Declined | withdrew | |
| Offered | Offer-Withdrawn | rejected | |
| Hired | Hired | hired | |

The user approved the outcome idea. The per-row outcomes above are Claude's
reading of each status and match how today's importer
(`server/src/zohoRecruit/mapping.ts`) treats them. "Not responding" as
`withdrew` is the least certain one.

Rows in the export whose stage is blank but whose status is set
(Interview-Scheduled ×22, Submitted-to-hiring manager ×1) go under the stage
the table gives.

**All of today's statuses go.** The current 40 rows of
`application_sub_statuses` (e.g. "Sourced — not yet contacted", "Offer
accepted", "Converted – employee", "Approved by the hiring manager", "Job
closed", "Candidate withdrew") are deleted, not retired, and the 37 Zoho
statuses above are the only ones left. Nothing uses them. As of 2026-11-05
there are zero applications. Code that refers to a deleted key (e.g.
`job_closed`, the hired-stage statuses, `awaiting_evaluation`) is changed to
the Zoho status or to the closure mark.

**Rules that depend on fixed statuses.** Migration 0088 protects four keys:
`applied`, `sourced`, `contact_attempted` and `contacted`. Keep those keys and
relabel them New, Associated, Attempted to Contact and Contacted. A new
application from the careers page lands on Screening / New. One HR sources
lands on Screening / Associated. The "not responding" rule and any others keep
their keys. Every application has a stage *and* a status from now on. Adding a
status on Hiring → Labels must ask for its outcome. Renaming keeps it.

**Where the stage logic lives today** (the builder must sweep it all):
- `CLOSED_STAGES` in `app/src/components/hiring/ApplicantsPanel.vue`,
  `app/src/lib/dashboard.ts` and `app/src/lib/hiringTabs.ts`
- 35 app files mention stage keys
- DB functions with `'rejected'` / `'withdrawn'` in their body:
  `set_application_status`, `withdraw_in_play`, `close_jobs`,
  `notify_application_owner`, `recruitment_report`, `reason_sub_status`,
  `remove_sub_status`, `backfill_sub_statuses`, `advance_offer`,
  `import_zoho_recruit`, plus the fill-on-hire trigger from 0090
- `withdrawn_reason` / `rejected_reason` on `applications`: the status now
  *is* the reason. Keep the columns for free-text detail.

## Import (decided: from the CSV, server-side)

- Runs with no browser involved (Node extract → JSON payload → one SQL
  function, the way `scripts/zoho-import.sh` works). It has a `--dry-run` that
  prints counts per stage/status and refused rows, and a `--commit` that is
  all-or-nothing.
- Candidates are matched by Candidate ID (`provider_ref`, e.g. `ZR_447_CAND`),
  jobs by Job Opening ID. The jobs are all still in the database.
- **The import never writes to `jobs`** (Claude's call). The CSV's job
  columns (Job Opening Status, Hiring Manager, Department, Assigned
  Recruiters) go only into the application's `custom.zoho`. A Job Opening ID
  that is not in the database is a refused row.
- **Owner** (Claude's call, as the old importer did it): Candidate Owner is
  matched to `people` by name and becomes `applications.owner_id` for each of
  that candidate's applications. A name with no match is reported and left
  empty, never invented. Import-time writes must not fire `candidate.assigned`
  notifications.
- **Contact rules** (Claude's call): per candidate, `do_not_contact` beats
  `contact_later` when the rows disagree, so the constraint
  `candidates_one_contact_rule` can never fail the commit. The reason text is
  "Zoho: <status>". The flags are set **only by the import**. Picking one of
  those statuses in the app keeps today's behaviour, where the dialog warns and
  the contact rule is a separate step. Moving off a status never clears a flag.
  Whether picking the status should set the flag remains the open product
  question recorded earlier.
- **Stage per status** comes from the table above, never from the file. In the
  export every status sits under exactly one stage (checked 2026-11-05), apart
  from the 23 blank-stage rows. A dry-run that finds a different stage
  reports it as a problem.
- Dates come from the CSV: received = Associated On, status date = Status
  Last Updated, hired = Hired Date. Fall back to Candidate Last Activity.
- Every Zoho fact goes under `custom.zoho`, verbatim.
- The two contact-rule statuses set the candidate flags from the table.
- Done means the counts per status in the app equal the counts per status in
  the CSV, with zero rows refused.
- The existing multi-table importer (`server/src/zohoRecruit/*`, plans
  052/055) reads a full Zoho export that is no longer on disk. Reuse its
  mapping and helpers where they fit, but its export reader does not apply.

## Staying under the Free limits (decided approach)

Budget: no request a screen makes returns more than about 100 rows or about
100 KB, whatever the data size, except for an explicit download a user
triggers.

1. **Home page.** Replace `loadPipelineApplications` (`pageAll` over every
   application on live jobs) with one database function that returns counts
   per job × stage × status plus the few "just applied" rows it shows. Same
   for `JobOpeningsPanel`'s `pageAll`.
2. **Lists page on the server.** Applicants, a job's applications
   (`JobPage.loadApplications` is unbounded today) and activity load about 50
   rows at a time, with filters and search done in SQL. Counts come from count
   queries, not by downloading rows.
3. **Notifications.** Poll only while the tab is visible
   (`visibilitychange`). The poll is a head-only unread count, and the list
   loads when the panel opens.
4. **Lookups** (stages, statuses, sources, companies, departments) are loaded
   once per session in a store, not on every screen.
5. **Files.** CVs are never in a list query. `extracted_text` is never
   selected by the app. Files are downloaded only on click, through signed
   URLs as today.
6. **Imports and bulk jobs** run in SQL, not through the API.

How to measure it is the builder's call. A test that fails on an unbounded
select over `applications`/`candidates` would be welcome.

## Constraints

- Vue 3 Composition API + Pinia + supabase-js, Postgres on Supabase, thin Node
  service. Migrations are numbered. The next one is `0095`. Apply a single file
  with `psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f …`.
- A push to `main` deploys production (peopleos.hut4.com). Once the user
  approves a release: migrate, verify, commit, push, in one go.
- RLS stays as it is. New functions follow the existing
  `app.has_capability` checks.
- Tests: Vitest for logic, Playwright for the critical hiring flow (E2E
  refuses production unless the user enables it).

## Left to the builder

The order of the work, the migration split, how the outcome is stored (a
column on `application_sub_statuses` is the obvious fit), the shape of the
summary function, UI details of paging, and how the `withdrawn_reason`/
`rejected_reason` fields are shown.

## Decided by the user after the review (2026-11-05)

- **Job closed / filled.** When `close_jobs`, `withdraw_in_play` or the
  fill-on-hire trigger closes candidates still in play, the candidate **keeps
  their Zoho status**. The application gets a closure mark instead (e.g.
  `closed_at` + `closed_reason` = job closed / position filled) and counts as
  finished everywhere the outcome is read. No "Job closed" status is added.
  The 0018 auto-withdraw that writes `stage_key = 'withdrawn'` must go too. So
  "finished" = outcome ≠ `open` **or** the closure mark is set.
- **CVs come back.** The 2,710 files in
  `~/Downloads/peopleos-backup-2026-11-05/files/` are re-attached to the
  re-imported candidates by Zoho Candidate ID. Map old candidate id →
  `provider_ref` using `db/candidates.csv` of the backup, and file metadata
  from `db/candidate_files.csv`, including `extracted_text` for search. The
  upload runs from this machine (ingress, no egress). This uses about
  290 MB of the 1 GB storage.
- **Job notes become notes.** "Job Notes Log (newest first)" (892
  applications) is split into separate dated notes with an author where the
  name matches `people` (otherwise none, with the Zoho name kept in the note's
  data), and shown with that application like notes written in the app. Where
  they are stored is the builder's call. The parsing of the log format must be
  checked in the dry-run (count of notes, refused fragments).
