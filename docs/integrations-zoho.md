# Zoho Projects sync

## What it does

A read-only mirror job: it pulls projects and project members from Zoho
Projects and writes them into `external_projects` and
`external_project_members`. It never writes anything back to Zoho — the
external system owns the facts, the portal only reflects them, with a
source and a freshness timestamp on every row
(`docs/hr-product-plan.md` §12 states the same contract for the leave
system; this applies it identically).

It is the only writer of those two mirror tables. The app reads them
read-only (company profile "Projects" tab, My workspace "My projects").

Scheduling (cron / `pg_cron`) is **deliberately out of scope** for now — run
it by hand or wire it into your own scheduler.

## Configuration

### Zoho OAuth credentials

Set these (repo-root `.env.local`, or real environment variables in
deployment — never commit real values):

- `ZOHO_CLIENT_ID`
- `ZOHO_CLIENT_SECRET`
- `ZOHO_REFRESH_TOKEN`
- `ZOHO_ACCOUNTS_HOST` (optional, defaults to `https://accounts.zoho.eu`)
- `ZOHO_API_HOST` (optional, defaults to `https://projectsapi.zoho.eu`)
- `ZOHO_PORTAL_ID` (optional — when unset, the sync looks up the first
  portal returned by the Zoho API)

To obtain a refresh token: open the Zoho API Console, create a **Self
Client**, generate a grant token with scope
`ZohoProjects.projects.READ,ZohoProjects.users.READ`, then exchange that
grant code for a refresh token. The refresh token does not expire under
normal use; the access token it mints is cached in-process for the life of
one sync run.

### Company mapping

Each company that should receive synced projects needs a row in
`integrations` for `provider_key = 'zoho_projects'`, with the mapping rule
in `config`:

```json
{ "project_ids": ["123", "456"], "name_prefix": "SNW-" }
```

A Zoho project belongs to a company when:

1. its id is listed in that company's `project_ids` (checked first, across
   all companies), **or**
2. no id matched anywhere, and its name starts with that company's
   `name_prefix`.

If a project's id is not listed anywhere, and either no `name_prefix`
matches or *more than one* company's `name_prefix` matches, the project is
a **routing exception**: it is never guessed into a company. It is skipped,
counted, and returned in the sync result's `unmatchedProjects`, so it is
visible without becoming a silent wrong-company assignment. Members whose
email does not match any known person's `work_email` are likewise never
guessed — they show up in `unmatchedMemberEmails`.

No company configured (no `integrations` row for `zoho_projects` at all) is
not an error: the sync logs that nothing is configured and returns an empty
result.

## Running it

```sh
cd server
npm run sync:zoho -- --dry-run   # reports what it would do; writes nothing
npm run sync:zoho                # writes for real
```

Always run `--dry-run` first after changing any company's mapping — it
reports project/member counts and the unmatched lists with zero writes, so
a bad `project_ids`/`name_prefix` value is visible before anything lands in
the mirror tables.

On success, every configured company's `integrations` row is updated to
`status: 'connected'` with a fresh `last_sync_at`. On failure, every
configured company's row is updated to `status: 'sync_issue'` with
`last_error` set to a short, secret-free message, and the process exits
with a non-zero code.

## What the app shows afterwards

- Company profile → **Projects** tab: the company's synced projects and
  their members.
- My workspace → **My projects**: the signed-in person's project
  memberships, across companies.

Both are read-only views over the mirror tables — there is no UI path that
edits them; the sync is the only writer.

# Zoho Recruit: a one-off file import, not a sync

Where the sync above is live and repeatable, this is the opposite shape: a
batch import from a CSV/attachment export, run by hand, once, through the
same kind of door the talent pool's UI uses
(`public.import_zoho_recruit(payload, commit)`, migration 0067 — see
[the data model](data-model.md) and `plans/052-talent-pool.md` §3 for the
full mapping and payload shape). There is no live connection to Zoho
Recruit and nothing is scheduled.

## What it does

Reads the Zoho Recruit export (`docs/Data_001/Data/*.csv`,
`docs/Attachments_001/`), maps its vocabulary onto the app's (candidate
status → application stage, `Source` → `candidate_sources.key`, department →
company), and writes jobs, candidates, applications, application events and
notes with the same per-row-verdict, dry-run-then-commit discipline as the
Field Notebook import (`import_field_notebook`, migration 0028; run by
`scripts/fn-import.sh`). Every imported candidate and application carries
`provider` / `source_provider = 'zoho_recruit'` and its Zoho id as
`provider_ref`, and keeps its original source label through `source_key`
(`head_hunt`, `linkedin_profile`, `linkedin_ad`, `careers_page`, `job_board`,
`referral`, `added_by_hand`, or `imported` when Zoho's `Source` was blank) —
never collapsed into one generic "imported" bucket unless that is what Zoho
itself recorded.

## Running it (in order)

1. **Extract** — pure, no database, no secrets:

   ```sh
   cd server && npm run import:zoho-recruit:extract
   ```

   Writes `.zoho-payload.json` (the `import_zoho_recruit` payload),
   `.zoho-files.json` (the file manifest) and `.zoho-review.json` (duplicate
   groups, stale applications, hires, unresolvable files) to the repo root.
   Prints counts only — never a name or an email — and exits 1 on an
   unknown status or source (fix `server/src/zohoRecruit/mapping.ts` first).

2. **Dry run** — reports what would happen, writes nothing:

   ```sh
   scripts/zoho-import.sh --dry-run
   ```

3. **Commit** — all or nothing:

   ```sh
   scripts/zoho-import.sh --commit
   ```

   Both call `public.import_zoho_recruit` as the platform admin
   (impersonated through the JWT claims, the way `scripts/fn-import.sh`
   does) and print the counts, refused rows, unresolved users, possible
   duplicates and the hires table from `<payload>.report.json`. Nothing
   from `.env.local` is printed.

4. **Files** — after a committed row import, since every manifest row needs
   its candidate already in the database:

   ```sh
   cd server && npm run import:zoho-recruit:files -- --dry-run
   cd server && npm run import:zoho-recruit:files -- --commit
   ```

   Uploads eligible attachments as `candidate_files` (`provider
   'zoho_recruit'`) in the private `candidate-files` bucket, at
   `candidate/{candidate_id}/{file_id}.{ext}` — the same shape
   `candidateFiles.ts` uses for files added from the app.

## What is skipped

- Notes from the Job Openings and Tasks modules — counted under
  `notes.skipped_modules`, never imported. Candidate-level notes with no
  application are counted under `notes.without_application`, not imported
  either — a seam for a later `candidate_notes` slice.
- Attachments that are calendar files, job summaries, spreadsheets,
  `.msg`/`.rar`, parented to a job or an interview rather than a candidate,
  or over 10 MB — each skipped with its reason and counted, never guessed.
- The Offer category of an attachment (`custom.zoho.category = 'Offer'`)
  lives on the files manifest only; `candidate_files` has no `custom` column,
  so the category is not stored.
- Candidates never associated with any job keep their Zoho status in
  `custom.zoho.status` only; no application is created for them.

## Re-running is safe

Every writer is keyed by the provider reference —
`candidates_provider_dedupe` on candidates, `applications_provider_dedupe`
on applications (extended the same way for `zoho_recruit` as for every
other provider); `zoho-recruit-files.ts` skips any manifest row whose
`provider_ref` is already in `candidate_files`. Running extract, dry run and
commit again over the same export finds every job, candidate and
application already there and reports them as skipped, not duplicated — so
fixing a handful of refused rows and running the same steps again is the
normal way to finish an import, not a special case.

## The history: notes, interviews, reviews

A second, later import (plan 055, migration 0070) over the same export:
`server/src/zohoRecruit/history.ts` builds the payload for
`public.import_zoho_history(payload, commit)`, the seam plan 052 left open —
the person-level notes it only counted, and the interviews/reviews whose
Zoho ids it preserved but never turned into rows.

**What comes in.** Three kinds, each mapped in `history.ts`:

- **Candidate notes** — every Candidates-module note not already attached to
  an application by the first import; Zoho's note type maps to
  `candidate_notes.kind`: `Notes` → `note`, `Call` → `call`, `LinkedIn Msgs *`
  → `message`, `Meeting` → `meeting`, `Change Status` → `status_change`,
  `Association`/`Unassociation` → themselves, `General Review` → `review`,
  `TASK` → `task`, `Others` (or anything unrecognised) → `other`.
- **Interviews** — become `interviews` rows on the matching application: the
  Zoho name decides `kind` (`phone` when it contains "Phone", else `other`,
  the name itself kept in `custom.zoho.name`); `status` is `cancelled` for a
  Cancelled row, else `completed`; the Zoho "Interview Status" is kept
  verbatim as the outcome, in `custom.zoho.outcome`.
- **Reviews** — become `scorecards` on the matching interview: Zoho's 1–4
  rating is both the scorecard's `rating` and its `recommendation` —
  4 → `strong_yes`, 3 → `yes`, 2 → `no`, 1 → `strong_no`.

**What is skipped, and why** — every skip is counted by reason in
`import_zoho_history`'s report, never guessed into place:

- Notes from the Interviews, Job Openings and Tasks modules
  (`notes.skipped_modules`) — out of scope, as in the first import.
- A note already attached to an application by the first import
  (`notes.already_attached`) — the extract leaves it out of the payload
  entirely, since that note's path stays 052's, not this one's.
- An interview whose (candidate, job) pair is not an already-imported
  application (`application_missing`) — the live export had 5.
- A review whose interview was never created, because its own row was
  skipped (`interview_missing`) — the live export had 20.
- A review whose (interview, author) pair already has a scorecard
  (`duplicate_author`) — but a **null** author is never a duplicate of
  anything: several unresolved reviewers, or the same unresolved reviewer
  more than once, all import as separate scorecards on one interview. The
  live export's 15 reviews by the same unresolved author on one interview
  came in as 15 separate scorecards, not one.

**Running it (in order)**, after the row import above:

```sh
npm --prefix server run import:zoho-history:extract   # writes .zoho-history.json, prints counts
scripts/zoho-import.sh --dry-run --history             # reports; nothing written
scripts/zoho-import.sh --commit  --history              # all or nothing
```

The dry run and commit report the same shape as the row import's — counts,
plus the skipped rows grouped by kind and reason (counts only, never a
name) — printed by the same `scripts/zoho-import.sh`.

Re-running is safe the same way: `candidate_notes`, `interviews` and
`scorecards` each carry a unique partial index on `(provider, provider_ref)`,
so a second dry run over the same export reports every row `already_imported`
and a second commit writes nothing new.
