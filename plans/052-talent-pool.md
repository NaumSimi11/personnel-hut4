# Plan 052: Sourcing — the talent pool

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.
> Migration **0067** (`supabase/migrations/0067_talent_pool.sql`); the smoke
> block `-- ================================================================ 0067`
> goes before `select 'SMOKE TESTS PASSED'` (smoke.sql:4814). Never print
> values from `.env.local` / `.env.hr-hut4.local`. Stage by explicit path,
> never `git add -A`: `docs/files 1/` and `docs/files 1.zip` are the
> maintainer's and are never staged (the handoff records that `-A` once
> swept them in); `docs/Data_001/` and `docs/Attachments_001/` are the Zoho
> export (real people; the pending `.gitignore` hunk covers them and is
> committed with this slice's four `.zoho-*` patterns) — read, never commit.

## Status

- **Priority**: P1 / **Effort**: L / **Risk**: MEDIUM (rewrites the one
  candidate visibility rule; a second object-path convention in the private
  bucket; imports 3,611 real people) / **Depends on**: 051
- **Category**: product. The Zoho Recruit export shows HR's real practice:
  3,611 candidates, 49 % head-hunted, 26 % captured from LinkedIn profiles,
  400 never attached to a job, 788 attached to two or more jobs over time,
  57 "never to be contacted again", 56 "contact in future", a CV for 2,496
  of them. The app only knows a candidate through an application to a job,
  creates a fresh row on every add, and hangs the CV off the application.
  This slice makes the candidate a first-class holding-wide record behind a
  deliberately granted capability, dedupes at every door without ever
  merging, stores the CV on the candidate, and imports the Zoho export
  through the same door a LinkedIn export will use later.
- **Design record**: three designs (risk-first, user-first, data-first) were
  judged on codebase fit, HR usefulness and data integrity; risk-first won
  2–1 and the grafts were verified on disk; a second adversarial pass over
  this document (SQL feasibility on a scratch Postgres 16, design fidelity,
  executor clarity) produced the precise contracts below. Outreach
  sub-statuses inside Screening (Contacted / Interested / Not responding…)
  are the next slice; §5 says where this one leaves the seam.

## Decisions the maintainer confirms before "go"

Defaults are what the plan implements; say otherwise and the plan changes.

- **D1 Departments → companies**: HUT 4, HUT 4 Capital, Corporate Services,
  Corporate Marketing, Multihem → `HUT4`; SYNAMI DOOEL, Synami Products,
  Synami Sales → `SYNA`; SNOWBALL → `SNOW`; Liquiditas → `LIQU`; Clip Media
  Group has no job or candidate. The Zoho department name stays in
  `jobs.custom.zoho.department`.
- **D2 Retention (legal call)**: import all 3,611 candidates and every
  storable file (2022–2026, no consent trail in Zoho); no purge in 052 —
  `archived_at` + `last_activity_at` are the hooks for a later rule.
  Alternatives: a cut-off on *created* since 2024-01-01 (keeps 2,339 plus
  every hire) or on *any activity* since 2024-01-01 (≈2,760 by Modified
  Time, plus every hire); or metadata for all and files only for the
  recent window. Say which stamp a retention rule would read.
- **D3 Stale applications**: the 1,332 non-terminal Zoho applications on
  Filled / Cancelled jobs are imported directly as `withdrawn` "Job closed"
  (their Zoho status in `custom.zoho.status`; a `null → <mapped stage>`
  event first when the mapped stage is not `new`, then `<mapped> →
  withdrawn` dated the job's close), so they do not sit as "in progress" on
  the Applicants tab and Home. Cancelled jobs have no Date Closed in the
  export (all 26): the close date is the job's Modified Time, and the row
  records `custom.zoho.close_date_assumed = true`. The 77 non-terminal rows
  on the two Inactive (→ `on_hold`) jobs stay live. One-line change in
  `staleRule` if they should keep the mapped stage.
- **D4 No grant backfill**: `candidates.source` is added to the Holding HR
  and Recruiter presets only (0002's rule: preset edits never change
  existing grants). Platform admins (Ivana) see the pool at once; the admin
  grants the key to the other Holding HR people from the access editor.
- **D5 Identity edits**: company reviewers keep today's right to edit name /
  contact / profile of a candidate who applied to their company; source,
  archive, provenance and the contact rule are locked to `candidates.source`
  and the RPCs.
- **D6 Files**: Upload CVs attaches the CV to the candidate (readable
  wherever the person applied); the per-application upload stays for
  job-specific material. The 1,181 LinkedIn HTML captures become
  `text/plain` "profile" files (tags stripped) with `extracted_text`; the
  .msg (14 MB), .rar, 3 .xlsx and 104 .ics are skipped and listed; the 4
  signed offers go in as candidate files (kind other).
- **D7 Notes**: the 1,212 Zoho notes whose candidate + job pair is an
  imported application (1,195 by the note's own candidate + job columns,
  17 interview-feedback notes resolved through `Interviews_001.csv`) become
  `application_events` notes prefixed `[Zoho <type> · <date> · <author>]`;
  the 1,758 candidate-level notes and the 36 job- / task-module notes are
  counted, not imported; the 104 interviews and 75 reviews wait for a
  `candidate_notes` slice (ids preserved in `custom.zoho`).
- **D8 Leftover test data**: the live "Ivana Frost · Frontend Dev · Offer"
  application and its candidate are deleted before the import (the dry run
  lists it as a possible duplicate otherwise). Say when.

The contact rule (never / contact later), the CV on the candidate and HR
confirming the 59 imported hires against employee records are the
outline's items 3, 2 and 6; archive is the pool's only delete for
non-admins (data-model.md:160). Nothing else was added.

## 1. What changes

### 1.1 Database (migration 0067)

Order inside the file: capability → lookup → helpers → columns and indexes
→ **backfills** → triggers and audit → `candidate_files` and storage →
functions → grants → report. Backfills run before any new trigger exists,
so they leave no candidate audit rows and never meet the field guard; the
`applications.source_key` backfill fires the existing touch and audit
triggers on every application (accepted: one activity row each).

**Capability** (0027 idiom, no backfill):
`('candidates.source', 'Recruitment', 'Work the talent pool (holding-wide)',
false, 75)`, dependency `candidates.source → candidates.view`, preset rows
for `Holding HR` and `Recruiter` (`permission_presets where company_id is
null`, `on conflict do nothing`). Company HR and Hiring Manager hold
`candidates.review` and today are accidental pool readers through the 0006
"no applications yet" fallback; that ends here.

**Lookup `candidate_sources`** (`key text primary key check (key ~
'^[a-z][a-z0-9_]{1,39}$')`, `label`, `sort_order`, `archived_at`; RLS read
by everyone signed in, written by admins; `grant select … to authenticated`,
`grant all … to service_role`). Seed, verbatim:

| key | label | sort |
|---|---|---|
| `head_hunt` | Head hunt | 10 |
| `linkedin_profile` | LinkedIn profile capture | 20 |
| `linkedin_ad` | LinkedIn advertisement | 30 |
| `careers_page` | Company careers page | 40 |
| `job_board` | Job board or advertisement | 50 |
| `referral` | Referral | 60 |
| `added_by_hand` | Added by hand | 70 |
| `imported` | Imported, source unknown | 80 |

`careers_page` **must** equal the `careers` channel label "Company careers
page" (0007:134 — `careers.spec.ts:178` and `reports.spec.ts:117` assert it)
and `added_by_hand` "Added by hand" (`reports.spec.ts:120`). Sources say how
a person came to HR's attention; `channels` stay publishing destinations.

**Key helpers** — `language sql immutable strict`, no `current_setting` /
`now()` inside; the generated columns reference **only** the helper
(`array_to_string` is STABLE in `pg_proc`, so the sort-and-join may live
only inside `name_key`; an inline expression is refused with 42P17):

- `app.phone_key(text)` — the last eight digits when at least eight are
  present (`077597288` → `77597288`, `+389 70 813 118` → `70813118`,
  `0038978316858` → `78316858`, `12345` → null). Never written back into
  `phone` (`careers.spec.ts:155-156` asserts the stored phone verbatim).
- `app.name_key(text)` — lower-cased, Latin diacritics folded via
  `translate`, bracketed parts dropped, non-letters to spaces, words sorted
  and joined (`Dimitar (Benjamin) Iliev` and `Iliev Dimitar` → `dimitar
  iliev`; `Fredrik Möllersten` → `fredrik mollersten`; Cyrillic stays
  Cyrillic). A suggestion key, never an identity.
- `app.linkedin_key(text)` — the `/in/` slug of a linkedin.com address,
  lower-cased, query and trailing slash stripped
  (`https://www.linkedin.com/in/John-Doe/?trk=x` → `john-doe`); null for
  anything else.
- `app.mask_email(text)` → `p***@example.test`; null without `@`.

All four are granted to `authenticated` (the generated columns evaluate
them when a reviewer updates `full_name` / `phone` / `linkedin_url`).

**`candidates` gains**: `provider text not null default 'manual'` (CHECK
`^[a-z][a-z0-9_]{1,39}$`; like `applications.source_provider` it is plain
text, never an FK to `providers`, whose rows render as "Not connected"
integrations), `provider_ref text` (CHECK `provider <> 'manual' or
provider_ref is null`; partial unique `candidates_provider_dedupe (provider,
provider_ref) where provider_ref is not null`), `source_key text not null
default 'added_by_hand' references candidate_sources`, `sourced_by uuid
references people`, `current_title`, `current_employer`, `location`,
`linkedin_url`, `skills text[] not null default '{}'`, `summary`,
`referred_by text` (Zoho's external referrals have no person row),
`do_not_contact boolean not null default false`, `do_not_contact_reason`,
`do_not_contact_at timestamptz`, `do_not_contact_by uuid references people`,
`contact_later boolean not null default false`, `contact_again_after date`,
`last_activity_at timestamptz not null default now()`, `archived_at`, and
three **stored generated columns** `phone_key = app.phone_key(phone)`,
`name_key = app.name_key(full_name)`, `linkedin_key =
app.linkedin_key(linkedin_url)`. CHECKs: `candidates_never_needs_reason`
(`not do_not_contact or nullif(trim(do_not_contact_reason), '') is not
null`), `candidates_one_contact_rule` (`not (do_not_contact and
contact_later) and (contact_again_after is null or contact_later)`),
`candidates_text_len` (name 1..200, title / employer / location /
referred_by ≤ 200, linkedin_url ≤ 300, summary ≤ 4000, ≤ 100 skills).
Indexes: `email`, `phone_key`, `name_key`, `linkedin_key`,
`last_activity_at desc`, and the missing `applications (candidate_id)`.
Backfill: candidates with a `careers` application get `provider 'careers'`,
`source_key 'careers_page'`; `last_activity_at = greatest(updated_at, max
of the applications' received_at / updated_at)`.

**`applications.source_key text references candidate_sources`** (nullable):
how *this* application came to be — backfilled from `source_channel_key`
(careers → `careers_page`, linkedin → `linkedin_ad`, indeed / other_manual
→ `job_board`). `source_channel_key` / `source_provider` / `provider_ref`
stay what they are.

**The visibility rule, rewritten in place** (never a parallel scope):

```sql
create or replace function app.can_source_candidates() returns boolean
language sql stable security definer set search_path = public as $$
  select app.has_capability_anywhere('candidates.source') $$;   -- admins included (0008)
create or replace function app.can_view_candidate(c uuid) returns boolean ... as $$
  select c is not null and (app.can_source_candidates()
    or exists (select 1 from public.applications a where a.candidate_id = c
               and app.has_capability(a.company_id, 'candidates.view'))) $$;
-- app.can_edit_candidate(c): the same with candidates.review
```

The 0006 fallback is gone: a candidate is born through the RPC, never
half-made under RLS. `drop policy write on public.candidates` (FOR ALL) and
create `upd for update using/with check (app.can_edit_candidate(id))` and
`del for delete using (app.is_admin())`; **no insert policy** —
authenticated inserts fail with 42501. `sel` (0006:249) is untouched.
Consequences (all checked): the only authenticated inserts are
`AddCandidateDialog.vue:44-50` and `UploadCvsDialog.vue:70-73` (both move to
the RPC); `careersRoutes.ts` uses the service client; every smoke insert
into `candidates` runs as superuser (lines 70, 302, 865, 1339, 3739); every
E2E seed uses `serviceClient()`. Existing application-less orphans on live
become pool rows for admins / sourcers only.

**Email comparisons.** `candidates.email`, `people.work_email` and
`people.personal_email` are `citext`; a `text` parameter compared against
them resolves to `text = text` (case-sensitive, index-blind — verified).
Every comparison in the new SQL casts the parameter: `c.email =
p_email::citext`, `p.personal_email = v_email::citext`; never `lower()` the
column. Existing rows are stored as typed (`AddCandidateDialog.vue:47`,
`careersRoutes.ts:203`).

**Flags and guards.** Two transaction-local flags: `app.candidate_rpc`
("a trusted writer is running": the public RPCs, the activity touch, the
import) and `app.candidate_import` ("historic rows are being written": the
import only). Rules: (a) only the outermost public function
(`upsert_sourced_candidate`, `add_candidate_to_job`, `set_contact_rule`,
`import_zoho_recruit`) and the touch trigger set a flag, and every setter
**restores the previous value** — `v_prev := current_setting(name, true)`
… `set_config(name, 'on', true)` … `set_config(name, coalesce(nullif(v_prev,
''), 'off'), true)` — never an unconditional `'off'` (verified: a nested
on/off clobbers the outer flag for the rest of the transaction);
(b) internals (`open_application`, `assert_contactable`, the matchers)
never touch the flags; (c) every guard predicate is the on-disk 0021/0022/
0023 idiom — `auth.uid() is not null and current_setting('app.candidate_rpc',
true) is distinct from 'on' and current_setting('app.candidate_import', true)
is distinct from 'on'` — so superuser fixtures (smoke.sql:3739-3747 runs with
`app.test_uid` still set), service-role writes and the migration itself
pass. Trigger functions are `security definer`.

- `app.assert_contactable(p_candidate uuid, p_override_wait boolean)` —
  plain `raise exception` (P0001) with the sentences every picker shows:
  "That candidate no longer exists." (22023); "<name> is archived. Restore
  the pool record first."; "<name> asked not to be contacted again:
  <reason>" — the reason only when `app.can_view_candidate(id)`, otherwise
  "<name> asked not to be contacted again."; "<name> asked to be contacted
  after <DD Mon YYYY>." when `contact_again_after > current_date` and not
  overridden. Granted to `authenticated`.
- `t0_guard_contact` **before insert** on `applications`: returns `new` when
  `auth.uid() is null` or either flag is on (the RPC already judged the rule
  with `override_wait`; the careers page is the person applying themselves;
  the import writes history); otherwise `assert_contactable(new.candidate_id,
  false)` — the wall holds for a direct PostgREST insert. Named `t0_` so it
  sorts before `t1_sync_company` and `touch` (existing triggers on
  `applications`: `touch`, `t1_sync_company`, `audit`, `t9_notify`).
- `t2_guard_fields` **before update** on `candidates`, predicate (c): a
  change to `provider`, `provider_ref`, `sourced_by`, `created_at` or
  `last_activity_at` → 42501 "Where a candidate came from is not editable.";
  a change to `do_not_contact`, `do_not_contact_reason`, `do_not_contact_at`,
  `do_not_contact_by`, `contact_later` or `contact_again_after` → 42501
  "Change the contact rule from the candidate's record."; a change to
  `source_key` or `archived_at` without `app.can_source_candidates()` →
  42501 "Changing talent-pool fields needs the "Work the talent pool"
  capability."; identity and profile fields stay editable by reviewers
  where the candidate applied (D5).
- `t8_touch_candidate` **after insert** on `applications` (and **after
  update of** `stage_key, owner_id, next_action, next_action_due`),
  `application_events` and `candidate_files`: the stamp is
  `applications.received_at` on insert, `applications.updated_at` on
  update, `created_at` for events and files; sets `app.candidate_rpc` around
  its own `update public.candidates set last_activity_at = v_at where id =
  … and last_activity_at < v_at` (never backwards — an imported 2023
  application leaves a 2023 activity) and restores the previous value.

**Audit** on `candidates` (there was none): `after insert or delete or
update of full_name, email, phone, custom, provider, provider_ref,
source_key, sourced_by, current_title, current_employer, location,
linkedin_url, skills, summary, referred_by, do_not_contact,
do_not_contact_reason, contact_later, contact_again_after, archived_at` —
`last_activity_at` and `updated_at` are deliberately outside the column
list; that is what keeps the touch silent — executing
`app.audit_redacted('email,phone,phone_key,linkedin_url,linkedin_key,name_key,summary,custom,do_not_contact_reason')`
(the argument is split on `,` with no trimming — no spaces). `candidates`
has no `company_id`, so these rows land with `company_id null` and are
readable by admins only (as `compensation_records`, 0018:53); the row itself
carries `do_not_contact_by/at`.

**`candidate_files`**: `id`, `candidate_id → candidates on delete cascade`,
`kind text not null default 'cv' check (kind in ('cv','cover_letter',
'portfolio','profile','other'))`, `storage_path text not null unique`
(CHECK `storage_path like 'candidate/' || candidate_id::text || '/%'`),
`original_name` (1..200), `mime_type`, `size_bytes >= 0`, `uploaded_by →
people`, `extracted_text` (plain text of a profile capture or a later
extraction), `provider` (shape CHECK), `provider_ref` (needs `provider`;
partial unique `candidate_files_provider_dedupe`), `created_at`. Index
`(candidate_id, created_at desc)`. Audit
`app.audit_redacted('extracted_text,original_name')`; the touch trigger.
Policies: `sel` via `app.can_view_candidate(candidate_id)`; `ins` via
`app.can_edit_candidate(candidate_id) and provider is null and
extracted_text is null` (imported rows come only from the import); `del`
via `can_edit_candidate`; no update. `grant select, insert, delete … to
authenticated; grant all … to service_role`.

**Storage**: objects at `candidate/{candidate_id}/{file_id}.{ext}` in the
existing private bucket `candidate-files`. `app.candidate_object_candidate
(object_name text) returns uuid` — `immutable`, granted to `authenticated`:
the second path segment as uuid when the first is `candidate` and the
second matches the uuid pattern, else null. Three permissive policies on
`storage.objects` beside the 0013 ones (they OR): "candidate files: pool
read" (select, `bucket_id = 'candidate-files' and
app.can_view_candidate(app.candidate_object_candidate(name))`), "pool
upload" (insert, `can_edit_candidate(...)`), "pool delete" (delete,
`can_edit_candidate(...)`). The 0013 resolver yields null for a first
segment that is not a uuid, so both shapes coexist; for a non-admin a
malformed `candidate/…` name is unreadable and unwritable (a platform admin
passes the 0013 policies through `has_capability(null, …)`). Bucket limits
unchanged (10 MB; pdf / doc / docx / txt / png / jpeg) — a profile capture
is stored as `text/plain`, never HTML. `application_files` stays:
job-specific material.

**`app.open_application(p_candidate uuid, p_job uuid, p_source_key text,
p_override_wait boolean) returns uuid`** (internal, revoked from public) —
where a pool application is born: `select … for update` on the candidate
("That candidate no longer exists." 22023); `assert_contactable`; the job
exists ("That job no longer exists." 22023); `draft`, `ready`, `open`,
`on_hold` are accepted (`hiring-pipeline.spec.ts:116-123` adds to a draft
job), `filled` / `closed` refuse "This job is <status>. Reopen it before
adding candidates."; the source exists unarchived ("Unknown candidate source
"<key>"." 22023); insert at `new` with `source_key`; on `unique_violation`
read `constraint_name` from `get stacked diagnostics` — `applications_one_open_per_candidate`
→ "<name> already has an open application for this job.", anything else
re-raised (the provider dedupe index must not be mislabelled). No event on
creation (as today; `received_at` records the moment). **Seam**: the one
line where the outreach slice sets an initial sub-status.

**Matching** (internal, revoked from public):

- `app.candidate_payload_problems(p jsonb) returns text[]` — one shape
  check shared by the RPC (raises the first, 22023) and the import
  (collects): "Enter the candidate's full name (2 to 200 characters).";
  "Enter a valid email or leave it empty." (lower-cased,
  `^[^@\s]+@[^@\s]+\.[^@\s]+$`); "Keep the phone number under 40
  characters."; linkedin_url ≤ 300, title / employer / location /
  referred_by ≤ 200, summary ≤ 4000 ("<field> is too long."); "Skills must
  be a list of short words." (jsonb array of strings, each ≤ 60, at most
  100); `custom` an object when present; "Unknown candidate source
  "<key>"." when given and not unarchived.
- `app.candidate_matches(p_email text, p_phone text, p_linkedin text,
  p_name text, p_exclude uuid) returns table (candidate_id uuid, matched_by
  text)` — over `candidates where archived_at is null and id is distinct
  from p_exclude`: `email = p_email::citext` → `email`; `phone_key =
  app.phone_key(p_phone)` (both non-null) → `phone`; `linkedin_key =
  app.linkedin_key(p_linkedin)` (both non-null) → `linkedin`; `name_key =
  app.name_key(p_name)` → `name`; one row per candidate keeping the
  strongest, ordered strongest first then `last_activity_at desc`, at most 5.
- `app.candidate_match_hint(p_id uuid, p_matched_by text) returns jsonb`,
  exactly: `{ id, full_name, match, visible: app.can_view_candidate(id),
  attachable: visible or match in ('email','phone','linkedin'),
  do_not_contact, contact_later, contact_again_after, email: visible ?
  email : match = 'email' ? app.mask_email(email) : null, phone,
  linkedin_url, current_title, current_employer, last_activity_at: visible
  only else null, applications: visible only — rows where
  app.has_capability(a.company_id, 'candidates.view') as { id, job_title,
  company_name, stage_key, received_at }, newest first, max 5 }`. Nothing
  about applications the viewer may not see, not even a count; the stored
  name is the accepted minimum disclosure. `type CandidateMatch` in
  `candidatePool.ts` is this shape verbatim.

**`public.upsert_sourced_candidate(p_provider text, p_ref text, p jsonb)
returns jsonb`** — the one door that creates a candidate from the app
(`manual` today, `linkedin_recruiter` / `csv` tomorrow with a ref per row).
Gates in order: signed in (42501 "Sign in to continue."); `p_provider ~
'^[a-z][a-z0-9_]{1,39}$'` (22023 "Name the provider, e.g. manual."); blank
`p_ref` → null; `manual` with a ref → 22023 "Manual records carry no
provider reference."; a ref → `app.can_source_candidates()` else 42501
"Importing provider records needs the "Work the talent pool" capability.";
`p->>'job_id'` given → the job exists (22023 "That job no longer exists.")
and `app.has_capability(job.company_id, 'candidates.review')` else 42501
"Adding a candidate to this job needs the "Record interview feedback"
capability in <company name>."; no `job_id` → `can_source_candidates()`
else 42501 "Adding to the talent pool needs the "Work the talent pool"
capability."; `attach_to` and `ignore_matches` both given → 22023 "Choose
one: attach or create."; shape check via `candidate_payload_problems`
(**skipped** for `attach_to`, where only `full_name` / `email` / `phone` /
`linkedin_url` are read). Sets `app.candidate_rpc` (restoring after).
Branches:

- **A** provider-keyed (`p_ref` not null): `select … for update` by
  `(provider, ref)`. Found → every payload key present overwrites its column
  (`full_name, email, phone, linkedin_url, current_title, current_employer,
  location, skills, summary, referred_by, source_key`), `custom = custom ||
  coalesce(p->'custom','{}')`; absent keys leave the column alone;
  `created_at`, the contact rule and `sourced_by` never touched; `action
  'updated'`. Not found → insert with `provider`, `provider_ref`, `source_key
  = coalesce(p->>'source_key', 'imported')`, `sourced_by = coalesce(
  (p->>'sourced_by')::uuid, me)`, `created_at = coalesce(
  (p->>'created_at')::timestamptz, now())`, `last_activity_at = coalesce(
  (p->>'last_activity_at')::timestamptz, created_at)`; `'created'`. Then
  `possible_duplicates` = hints for `candidate_matches(...)` over the other
  rows — reported, never merged, never blocking.
- **B** manual with `attach_to`: the row exists (22023) and is unarchived
  ("<name> is archived. Restore the pool record first."); attachable =
  `can_view_candidate(id)` or the payload's `email` equals the row's
  (`::citext`), or `app.phone_key(payload phone) = phone_key`, or
  `app.linkedin_key(payload linkedin_url) = linkedin_key`; otherwise 42501
  "You cannot attach to that candidate."; no identity write; `'attached'`.
- **C** manual, no `attach_to`: `matches := candidate_matches(email, phone,
  linkedin_url, full_name, null)`; non-empty and not `ignore_matches` →
  return `{ action: 'matches', matches: [hints] }` **without writing**;
  otherwise insert (`provider 'manual'`, `provider_ref null`, `source_key
  coalesce(p->>'source_key','added_by_hand')`, `sourced_by = me` — an admin
  may pass `sourced_by`; `custom = coalesce(p->'custom','{}')`); `'created'`.
- **D** `job_id` given (after A / B / C): `open_application(v_id, job_id,
  coalesce(p->>'application_source_key', case when action = 'attached' then
  'added_by_hand' else v_source_key end), coalesce((p->>'override_wait')::
  boolean, false))`.

Returns `{ action: 'created'|'updated'|'attached'|'matches', id,
application_id, matches, possible_duplicates }`.

**`public.add_candidate_to_job(p_candidate_id uuid, p_job_id uuid,
p_source_key text default 'head_hunt', p_override_wait boolean default
false) returns jsonb`** — "Source from pool" and the record's *Add to job*:
signed in; the job exists (22023); `candidates.review` in its company (the
sentence above); `can_view_candidate(p_candidate_id)` else 42501 "You cannot
see that candidate."; flag on; `open_application`; returns `{ application_id }`.

**`public.set_contact_rule(p_candidate_id uuid, p jsonb) returns jsonb`** —
signed in; `can_source_candidates()` else 42501 "Changing the contact rule
needs the "Work the talent pool" capability."; the candidate exists (22023);
`p->>'rule'` in `ok` / `later` / `never` else 22023 "Pick a contact rule.".
`never` needs `p->>'reason'` trimmed non-empty (22023 "Say why this person
must not be contacted again.") → `do_not_contact true, reason,
do_not_contact_at now(), do_not_contact_by me, contact_later false,
contact_again_after null`; `later` → `do_not_contact false, reason / at /
by null, contact_later true, contact_again_after = p->>'contact_again_after'`
(null allowed; a date must be `>= current_date`, 22023 "Pick a date from
today on."); `ok` → everything cleared. Flag on around the update. Returns
the row's contact columns.

**`public.search_candidates(p jsonb) returns jsonb`** — signed in;
`can_source_candidates()` else 42501 "The talent pool needs the "Work the
talent pool" capability."; `security definer` (the gate already means "sees
the whole pool"); the applications sub-list is scoped explicitly. Payload:
`q`, `source_key`, `contact` in `any | ok | do_not_contact | wait`,
`activity` in `any | 90d | 1y | older`, `company_id`, `include_archived`
(default false), `limit` 1..100 (default 50), `offset` ≥ 0. Where:
`(include_archived or archived_at is null)`; `q` trimmed non-empty →
`name_key like '%' || app.name_key(q) || '%'` (`%` / `_` in `q` escaped) `or
email::text ilike '%q%' or (app.phone_key(q) is not null and phone_key =
app.phone_key(q)) or (app.linkedin_key(q) is not null and linkedin_key =
app.linkedin_key(q)) or current_title ilike '%q%' or current_employer ilike
'%q%' or exists (select 1 from unnest(skills) s where s ilike '%q%')`;
`source_key`; `ok` = `not do_not_contact and not contact_later`,
`do_not_contact`, `wait` = `contact_later`; `90d` / `1y` = `last_activity_at
>= now() - interval`, `older` = `< now() - interval '1 year'`; `company_id`
= `exists (select 1 from applications a where a.candidate_id = c.id and
a.company_id = p.company_id and app.has_capability(a.company_id,
'candidates.view'))`. Order `last_activity_at desc, full_name`. Returns
`{ total, rows }`; row exactly: `id, full_name, email, phone, current_title,
current_employer, location, skills, source_key, source_label, provider,
do_not_contact, contact_later, contact_again_after, last_activity_at,
archived_at, files_count, applications: [{ id, job_id, job_title,
company_id, company_name, stage_key, received_at }]` — visible applications
only (`candidates.view` in the company), newest 3.

**`public.link_hired_application(p_application_id uuid, p_person_id uuid
default null) returns jsonb`** — HR confirms (or declines) the employee
record for an imported hire: signed in; the application exists (22023);
`app.has_capability(a.company_id, 'employment.edit')` else 42501 "Linking a
hire needs the "Edit employment information" capability in this company.";
`stage_key = 'hired'` else "Only hired applications can be linked to an
employee record."; `employment_period_id is null` else "This application is
already linked to an employee record.". `p_person_id null` → decline:
`custom.zoho.proposed_person = null`, `custom.zoho.link_declined_by / _at`
(deep-merged), returns `{ linked: false }`. Otherwise the person needs an
`employment_periods` row in `a.company_id` — the one whose `start_date` is
nearest `coalesce((a.custom #>> '{zoho,hired_date}')::date,
a.received_at::date)`; none → "<name> has no employment record in
<company>."; set `employment_period_id` (`unique_violation` → "That
employment record is already linked to another application."); insert
`application_events (kind 'note', body 'Linked to the employee record of
<person> by <me>.', actor_id me)`; returns `{ linked: true,
employment_period_id, person_id }`. Never creates a person (blueprint §5).

**`public.import_zoho_recruit(p_payload jsonb, p_commit boolean default
false) returns jsonb`** — the shape and discipline of `import_field_notebook`
(0028): "Sign in to continue." / "Importing from Zoho Recruit needs platform
admin access." (42501); both flags on (restored after); pass 1 decides every
row and builds verdicts; `p_commit = false` returns the report without
writing; `p_commit = true` raises "Import refused: <n> rows have problems.
Fix the extract and run again." when any row is refused (all or nothing);
pass 2 writes, each row insert wrapped so a constraint failure re-raises as
"Row <zoho_id> (<kind>): <message>"; verification (rows created = rows
planned, else "Verification failed: …"); one `activity_log` row
`entity_type = 'zoho_recruit_import'` with the counts on commit. Payload,
passes and report in §3.

**`recruitment_report`** — defined once (0015:23), re-created from that body
with two lines changed: the sources subquery gains `left join
public.candidate_sources cs on cs.key = a.source_key` before the channels
join, and **both** the select label (0015:88) and its `group by` (0015:99)
become `coalesce(cs.label, c.label, 'Added by hand')`. Old careers rows and
new `careers_page` rows share "Company careers page"; null stays "Added by
hand", never guessed.

**Grants.** Keep / grant EXECUTE to `authenticated`: `app.can_view_candidate`,
`app.can_edit_candidate`, `app.can_source_candidates`,
`app.candidate_object_candidate`, `app.phone_key`, `app.name_key`,
`app.linkedin_key`, `app.mask_email`, `app.assert_contactable` (policy
expressions and generated columns run as the calling role — 0006:104-110,
0013:78). Revoke from `public` (postgres-only callers):
`app.open_application`, `app.candidate_payload_problems`,
`app.candidate_matches`, `app.candidate_match_hint`. The six public
functions: `revoke all … from public, anon; grant execute … to
authenticated` (0028:417-418), plus `service_role` on
`upsert_sourced_candidate`. Schema `app` usage is already granted (0002:127).

### 1.2 Server

- `careersRoutes.ts`: additive keys only — the candidate insert (`:200-204`)
  gains `provider: 'careers', source_key: 'careers_page'`; the application
  insert (`:213-220`) gains `source_key: 'careers_page'`. The oldest-exact-
  email reuse (the one sanctioned automatic attach — the applicant
  re-applying), the rollback and the CV in `application_files` stay;
  `careers.spec.ts` stays green ("via Company careers page", `:178`).
- New `server/src/zohoRecruit/{csv,dates,mapping,payload,files}.ts` with
  tests (pure), `server/src/zohoRecruit/fixtures/` (3 synthetic rows, no
  real PII), `server/scripts/zoho-recruit-extract.ts`,
  `server/scripts/zoho-recruit-files.ts`; `package.json` scripts
  `import:zoho-recruit:extract` (runs exactly the §3 command) and
  `import:zoho-recruit:files`; devDependency `csv-parse` (RFC 4180, quoted
  multi-line fields). `.gitignore`: `.zoho-payload*.json`,
  `.zoho-files*.json`, `.zoho-review*.json`, `.zoho-report*.json` next to
  `.fn-payload*.json`.

### 1.3 App

- **Types** (`database.ts`, hand-maintained): `candidates` Row gains
  (alphabetical) `archived_at`, `contact_again_after`, `contact_later:
  boolean`, `current_employer`, `current_title`, `do_not_contact: boolean`,
  `do_not_contact_at`, `do_not_contact_by`, `do_not_contact_reason`,
  `last_activity_at: string`, `linkedin_key`, `linkedin_url`, `location`,
  `name_key`, `phone_key`, `provider: string`, `provider_ref`,
  `referred_by`, `skills: string[]`, `source_key: string`, `sourced_by`,
  `summary` (Insert / Update: the same minus the three generated keys, all
  optional); relationships `candidates_source_key_fkey`,
  `candidates_sourced_by_fkey`, `candidates_do_not_contact_by_fkey`. New
  blocks `candidate_files` (`candidate_files_candidate_id_fkey`,
  `candidate_files_uploaded_by_fkey`), `candidate_sources`
  (`Relationships: []`); `applications.source_key: string | null` +
  `applications_source_key_fkey`. Functions: `add_candidate_to_job: { Args:
  { p_candidate_id: string; p_job_id: string; p_override_wait?: boolean;
  p_source_key?: string }; Returns: Json }`, `import_zoho_recruit: { Args:
  { p_commit?: boolean; p_payload: Json } }`, `link_hired_application: {
  Args: { p_application_id: string; p_person_id?: string | null } }`,
  `search_candidates: { Args: { p: Json } }`, `set_contact_rule: { Args: {
  p: Json; p_candidate_id: string } }`, `upsert_sourced_candidate: { Args:
  { p: Json; p_provider: string; p_ref?: string | null } }` — all `Returns:
  Json`.
- **`lib/candidatePool.ts`** (vitest beside it): `phoneKey` / `nameKey` /
  `linkedinKey` / `maskEmail` — browser mirrors with the SQL fixtures;
  `longDate(iso)` → `12 Oct 2026` (`shortDate` in `lib/leave.ts` has no
  year); `type PoolRow` (the search row), `type PoolFilters = { q;
  sourceKey; contact; activity; companyId; showArchived }`,
  `poolPayload(filters, page)`, `poolFiltersFromQuery(route.query)` ↔
  `poolQuery(filters)` round-trip over the keys `q, source, contact,
  activity, company, archived`; `contactState(c, today)` → `ok |
  do_not_contact | wait`; `contactBadge(c, today)` → `''` / `Do not
  contact` / `Contact later` / `Contact after 12 Oct 2026`; `type
  CandidateMatch` (the hint, verbatim); `matchSentence(m)` → "This looks
  like <name> (same email)." / "(same phone)" / "(same LinkedIn profile)" /
  "(same name — check before attaching)"; `matchHistoryLine(m)` → "Applied
  to <job_title> at <company_name> — <stage>, <Mon YYYY>." (newest visible
  application) / "Already in the talent pool." (visible, none) / "Already
  in the talent pool — details are outside your companies." (not visible);
  `contactLine(m)` → "Asked not to be contacted." / "Asked to be contacted
  after <DD Mon YYYY>."; `NOT_ATTACHABLE = 'In the pool, but you would need
  the same email, phone or LinkedIn to use this record.'`;
  `SOURCE_FALLBACK_LABEL = 'Added by hand'`.
- **`lib/candidateFiles.ts`**: `candidateFileObjectPath(candidateId,
  fileId, mime)` = `candidate/${candidateId}/${fileId}.${ext}`;
  `CANDIDATE_FILE_KINDS` (`cv` CV, `cover_letter` Cover letter, `portfolio`
  Portfolio, `profile` Profile capture (text), `other` Other);
  `uploadCandidateFile({ candidateId, file, kind, uploadedBy })` — the row
  id is generated first so the object path carries it; upload the object →
  insert the row → remove the object on row failure (the
  `uploadApplicationFile` shape); `removeCandidateFile(id, path)` (row
  first; zero rows → "You do not have permission to remove this file.");
  `listCandidateFiles(candidateId)`. `applicationFiles.ts` exports
  `extensionFor(mimeType)` (the `EXTENSION_BY_TYPE` lookup) so both share
  it; `validateApplicationFile`, `signedFileUrl`, `formatBytes`,
  `FILE_ACCEPT` reused.
- **`lib/jobWorkspace.ts`** — `friendlyRecruitmentError` gains one case:
  `/row-level security/` on a candidates write → "This needs the "Work the
  talent pool" capability, or "Record interview feedback" where the
  candidate applied." The RPCs already speak in sentences and are shown
  verbatim.
- **Talent pool tab** (`/hiring?tab=pool`): `HiringRequestsPage.vue` — `TABS`
  becomes a computed list; `{ id: 'pool', label: 'Talent pool' }` exists
  only when `auth.isAdmin || auth.canAnywhere('candidates.source')`; an
  unknown or hidden tab falls back to `requests`; `data-testid=
  "hiring-tab-pool"` from the existing loop; `<TalentPoolPanel v-else-if=
  "activeTab === 'pool'" />`. **`hiring/TalentPoolPanel.vue`** (the
  `ApplicantsPanel.vue` skeleton, `data-testid="talent-pool"`): `.card-head`
  "Talent pool" / "Everyone recruitment has found, added or imported —
  across the holding. Attach a person to a job instead of typing them
  again."; head action **Add to pool** (`pool-add`, `AddCandidateDialog` in
  pool mode). Filters: search (`pool-search`, placeholder "Name, email,
  phone, LinkedIn, title, skill", debounced 300 ms), `CompanyFilter`
  labelled *Applied to* with `all-label="Applied anywhere"` (unarchived
  companies where `auth.can(id, 'candidates.view')`), source select ("Any
  source" + unarchived sources), contact select ("Anyone" / "Can be
  contacted" / "Do not contact" / "Contact later"), activity select ("Any
  time" / "Last 90 days" / "Last year" / "Older than a year"), checkbox
  "Show archived"; mirrored into `route.query` so a search survives opening
  a record. Data: `search_candidates`, 50 a page, **Show more** while
  `rows.length < total`, count line "3,611 people · showing 50". Table:
  Person (`<b>` name → route `candidate`; `<small class="sub">` email ·
  phone), Title (`title @ employer`), Skills (first 4, `+n`), Source
  (label badge), Applications ("3 · latest: Frontend Developer, Snowball —
  rejected" from the visible list; "—" when none visible, never a zero),
  Last activity (`shortDate`), Rule (`contactBadge`: amber *Do not contact*,
  blue *Contact later* / *Contact after …*, grey *Archived*), actions
  **Open** · **Add to job** (`SourceToJobDialog`; disabled with a `title`
  when flagged or archived). Rows `pool-row-<id>`. States: "Loading the
  talent pool…"; "The talent pool is empty. Add a candidate or import an
  export."; "No candidates match." + *Clear filters*; "Could not load the
  talent pool." + Retry.
- **`pages/CandidatePage.vue`** (`/hiring/candidates/:candidateId`, route
  name `candidate`, registered after `application` in `router/index.ts`;
  no nav change). Load `candidates` by id with `source:candidate_sources
  (label), sourcer:people!candidates_sourced_by_fkey(full_name),
  flagged_by:people!candidates_do_not_contact_by_fkey(full_name)`; no row →
  `missingRecordMessage({ noun: 'candidate', lookupFailed, seesEverything:
  auth.isAdmin })` ("This candidate is not in your companies." for the
  not-found case). `canEditPool = auth.isAdmin ||
  auth.canAnywhere('candidates.source')`; `canEditIdentity = canEditPool ||
  applications.some(a => auth.can(a.company_id, 'candidates.review'))`
  (hints; the policy and the guard decide). Head: eyebrow "Talent pool ·
  <source label> · added <shortDate> by <sourcer or —>" for pool holders,
  "Candidate · <source label>" otherwise; imported rows say "Imported from
  Zoho Recruit (<display id>)"; `<h1>` name; `.meta` title @ employer ·
  location · email · phone · LinkedIn ↗; badges `contactBadge` / *Archived*;
  when flagged, a red line "Asked not to be contacted again — <reason>
  (<flagged_by>, <shortDate do_not_contact_at>)". Actions: **Add to job**
  (primary; disabled with the never sentence when flagged / archived),
  **Contact rule** (`canEditPool`), **Archive** / **Restore** (`canEditPool`;
  `dialogs.confirmAction({ eyebrow: 'Talent pool', title: 'Archive <name>?',
  hint: 'They leave the pool and every picker; their applications and files
  stay. You can restore them later.', confirmLabel: 'Archive', danger: true
  })` → `candidates.update({ archived_at })`). Cards: **Applications**
  (`applications` where `candidate_id`, select `id, company_id, stage_key,
  received_at, source_key, job:jobs(id, title, company:companies(name))`
  newest first, RLS-scoped; rows link to `application` / `job`; empty "No
  applications you can see."); **Files** (`CandidateFilesCard` — props
  `{ candidateId, canEdit: canEditIdentity }`; a copy of
  `ApplicationFilesCard` over `candidate_files` via `lib/candidateFiles.ts`;
  `uploader:people!candidate_files_uploaded_by_fkey(full_name)`; kind select
  from `CANDIDATE_FILE_KINDS`; download = signed URL, the same Safari
  pattern; remove via `confirmAction`; empty "No files yet. The CV goes here
  — it follows the person to every job."); **Details** (`<form>`: a
  `<fieldset :disabled="!canEditIdentity">` with Full name, Email, Phone,
  LinkedIn URL, Current title, Current employer, Location, Skills
  (comma-separated ↔ `string[]`), Summary, Referred by; a second `<fieldset
  :disabled="!canEditPool">` with Source; save →
  `candidates.update({...}).eq('id', id).select('id').maybeSingle()`, `!data`
  → `friendlyRecruitmentError`; trigger sentences shown as returned);
  **Education** (`custom.education[]` as "Institute — degree, major ·
  2015–2019", years only; absent when empty); **Contact** ("Can be
  contacted" / "Contact later, after <longDate>" / "Asked not to be
  contacted: <reason>" + the **Contact rule** button).
- **`components/ContactRuleDialog.vue`** (`contact-rule`): eyebrow *Talent
  pool*, title "How may we contact <name>?"; radios **Can be contacted** /
  **Contact later** (optional `<input type="date" :min="todayDb()">` "not
  before") / **Never contact again** (`contact-rule-never`; textarea
  `contact-rule-reason` "Why? Everyone who tries to add them to a job sees
  this.", required); hint "Never blocks every "Add to job" for this person
  until the rule is changed. Contact later only warns."; Save
  (`contact-rule-save`) → `set_contact_rule`; refusals verbatim.
- **`components/CandidateMatches.vue`** (`candidate-matches`; both add
  dialogs): props `{ matches: CandidateMatch[]; mode: 'job' | 'pool' }`;
  emits `attach(id)`, `createNew`, `back`. Eyebrow *Before saving*, title
  "Is this the same person?"; per match (`match-<id>`): name in bold,
  `matchSentence`, `matchHistoryLine`, `contactLine`, badges; in `job` mode
  **Attach to this job** (`match-attach-<id>`) only when `attachable` and
  not `do_not_contact`, otherwise the muted `NOT_ATTACHABLE` text or the
  never sentence; **Open** link to `candidate` when `visible`. Footer:
  **Back** · **Create a new candidate anyway** (`match-create-new`,
  secondary). Nothing pre-selected.
- **`AddCandidateDialog.vue`** — props `{ jobId?: string; companyId?:
  string }` (pool mode when `jobId` is absent). Fields: Full name
  (`#ac-name`), Email (`#ac-email`), Phone (`#ac-phone`), new optional
  LinkedIn profile (`#ac-linkedin`, ≤ 300) and Current title (`#ac-title`,
  ≤ 200); pool mode adds a Source select (default Head hunt; job mode sends
  `added_by_hand`). Title "Add a candidate." (job) / "Add to the talent
  pool." (pool); the button stays **Save candidate** in job mode
  (`hiring-pipeline.spec.ts:123`, `job-workspace.spec.ts:191` click it),
  **Add to pool** in pool mode. Submit → `supabase.rpc('upsert_sourced_candidate',
  { p_provider: 'manual', p_ref: null, p: { full_name, email, phone,
  linkedin_url, current_title, source_key, job_id } })`; `action ===
  'matches'` → the form is hidden and `CandidateMatches` renders in its
  place; `attach(id)` → the same call with `attach_to: id`; `createNew` →
  with `ignore_matches: true`; `back` → the form again with its values
  intact. Emits `created` (job) / `created(id)` (pool → the panel routes to
  the record). Errors: RPC sentences verbatim; `friendlyRecruitmentError`
  for RLS text. The doc comment: "offers a match first, never merges by
  itself".
- **`UploadCvsDialog.vue`** — `Row` gains `matches: CandidateMatch[] |
  null`, `attachTo: string | null`, `ignoreMatches: boolean`; state adds
  `'duplicate'`. `saveOne(i)` → `upsert_sourced_candidate('manual', null,
  { full_name, email, source_key: 'added_by_hand', job_id, attach_to?,
  ignore_matches? })`; `action === 'matches'` → `state 'duplicate'` and the
  row shows, inline under it, `matchSentence` + `matchHistoryLine` per
  match with **Attach to this job** / **Create a new candidate anyway**
  buttons; a choice sets `attachTo` / `ignoreMatches` and **re-runs
  `saveOne(i)` immediately**; a row matching the same existing candidate as
  an earlier row shows "Also matched by row <n>". After `created` /
  `attached`: `uploadCandidateFile({ candidateId: result.id, file, kind:
  'cv', uploadedBy })`; a failed upload after a successful RPC marks the
  row `failed` with "Candidate added, but the CV did not upload — attach it
  from their record." (no rollback). `application_files` is no longer
  written here. Hint: "Names are guessed from the file names; fix them here
  before saving. Every candidate starts at "New" with the CV on their
  record." The dialog closes only when every row is `done`.
- **`components/SourceToJobDialog.vue`** (`source-to-job`; record → job):
  props `{ candidateId; candidateName; contactAgainAfter }`; loads `jobs`
  select `id, title, status, company_id, company:companies(name)` where
  `status in ('ready','open','on_hold')` (RLS: `jobs.view`), narrowed to
  companies where `auth.can(company_id, 'candidates.review')`;
  `CompanyFilter` with `all-label="All companies"`; a `<select>`
  (`source-job-select`) grouped by company; source select default Head
  hunt; a future `contact_again_after` shows the amber line "<name> asked
  not to be contacted before <longDate>." and the button reads **Add
  anyway** (`p_override_wait: true`); submit (`source-job-submit`) →
  `add_candidate_to_job`; on success emits `added(applicationId)` and
  **navigates to the new application**. Title "Add <name> to a job."; hint
  "The application starts at "New"."
- **`components/PickFromPoolDialog.vue`** (`pick-from-pool`; job →
  candidates): props `{ jobId; companyId; jobTitle }`; search
  (`pool-search`, ≥ 2 chars, debounced 250 ms) → `search_candidates({ q,
  limit: 20 })`; rows: name, `title @ employer`, source, `contactBadge`, an
  *In pipeline* grey badge when the candidate already has an open
  application on this job (from JobPage's loaded rows); **Add to this job**
  (`pool-pick-<id>`) — absent for `do_not_contact` and archived rows (badge
  only), disabled for *In pipeline*; a future `contact_again_after` →
  `dialogs.confirmAction({ eyebrow: 'Talent pool', title: '<name> asked not
  to be contacted before <longDate>.', hint: 'Add them to <jobTitle>
  anyway?', confirmLabel: 'Add anyway' })` then `p_override_wait: true` →
  `add_candidate_to_job(id, jobId, 'head_hunt', override)` → the row shows
  *Added*; the dialog stays open so several can be added; Close emits
  `created`. Empty search "Type a name, email, LinkedIn address, title or
  skill."; no rows "Nobody in the pool matches." Title "Source from the
  talent pool."
- **`JobPage.vue`** Applications tab: **Source from pool** (`source-from-pool`,
  `v-if="auth.isAdmin || auth.canAnywhere('candidates.source')"`) before
  *Add candidate*, opening `PickFromPoolDialog` with `@created=
  "loadApplications"`. `loadApplications` adds `source_key,
  source:candidate_sources(label)` and `candidate:candidates(id, full_name,
  email, phone, do_not_contact, contact_again_after)`; each row's `<small>`
  gains "· via <source label>" and a *Do not contact* badge; the name links
  to `candidate` for pool holders, else to the application as today.
- **`ApplicationPage.vue`**: the select adds `source_key` and
  `candidate:candidates(id, full_name, email, phone, linkedin_url,
  do_not_contact, do_not_contact_reason, contact_later,
  contact_again_after, custom)`; loads `candidate_sources` beside
  `channels`; the "via" line = source label → channel label → "added by
  hand"; `contactBadge` next to the stage badge; the candidate name links
  to `candidate` for pool holders. Files: `CandidateFilesCard` (`canEdit =
  canReview`) under `ApplicationFilesCard` with the heading "Candidate's
  files — shared across their applications"; `ApplicationFilesCard`'s
  heading becomes "Files for this application". **`ImportedHireCard.vue`**
  (`hire-link-card`) when `stage_key === 'hired' && !employment_period_id
  && custom.zoho` and `auth.can(company_id, 'employment.edit')`: "Zoho
  Recruit recorded this hire on <longDate custom.zoho.hired_date>."; with
  `custom.zoho.proposed_person`: "Proposed employee record: <full_name>
  (matched by <email | phone | name>)."; a `<select>` of people employed in
  this company (`employment_periods` select `person_id, start_date,
  person:people(full_name)` where `company_id`, under RLS — `people.view`,
  which `employment.edit` requires), pre-selected on the proposal; **Link
  to this employee** → `confirmAction` → `link_hired_application(id,
  personId)`; **Not the same person** → `confirmAction` →
  `link_hired_application(id, null)` (clears the proposal; the picker
  stays). Without a proposal: "No employee record was proposed — pick one,
  or leave it unlinked."
- **The two unbounded lists** (after 4,157 historic applications land;
  PostgREST's default `max-rows` is 1,000 and nothing in the repo sets it):
  `ApplicantsPanel.vue:38-43` sends the stage filter to the query (`live` →
  `.not('stage_key', 'in', '(hired,rejected,withdrawn)')`, a key → `.eq`,
  `all` → nothing), always `.limit(1000)`, reloads on stage change, and
  shows "Showing the newest 1,000 — narrow the filters to see older ones."
  when exactly 1,000 come back; `HomePage.vue:254-258` scopes the pipeline
  to live roles — `job:jobs!inner(title, status, company:companies(name))`
  + `.in('job.status', ['ready','open','on_hold'])` (the `!inner` +
  embedded-filter idiom `careersRoutes.ts:176-179` uses) + `.limit(1000)`;
  the dashboard E2E seeds `ready` / `open` jobs. The tile says: the
  pipeline of live roles.
- Gating (hints; RLS and the RPCs decide): pool tab, Add to pool, Source
  from pool, contact rule, source, archive, record links → `auth.isAdmin ||
  auth.canAnywhere('candidates.source')`; Add candidate / Upload CVs /
  attach / Add to job → unchanged buttons, the RPC refuses with a sentence;
  imported-hire card → `auth.can(company, 'employment.edit')`.

### 1.4 Documentation

`docs/data-model.md`: the candidates row of the capability table (:172)
becomes "`candidates.view` via the candidate's applications, or
`candidates.source` anywhere (the holding's talent pool)" / "`candidates.review`
via applications, or `candidates.source` anywhere; creation only through
`upsert_sourced_candidate`; the contact rule through `set_contact_rule`"; a
paragraph in the recruitment section: identity is holding-wide, history is
company-scoped; `candidate_files` beside `application_files` (:97-100) with
the `candidate/{id}/…` path. `docs/integrations-zoho.md`: a section "Zoho
Recruit: a one-off file import, not a sync" — imported rows carry `provider
= 'zoho_recruit'` and their original source label, the four commands, what
is skipped, re-runs skip. `plans/README.md`: update the 052 row's status;
`docs/development-plan.md`: a Done row and item 5 of "Next" says the Zoho
history is in; `docs/session-handoff.yaml` state / next.

## 2. Tests

### 2.1 Smoke (block 0067)

Fixtures as superuser: P1 `80000000-0000-0000-0000-000000000671` ("Pool
Person", email stored as `Pool@Example.test` — mixed case on purpose, phone
`+389 70 000 067`, `provider 'zoho_recruit'`, `provider_ref 'Z-1'`,
`linkedin_url 'https://www.linkedin.com/in/pool-person/'`); P2 `…0672`
("Never Person", `do_not_contact`, reason "Asked us to stop.",
`do_not_contact_at now()`); P3 `…0673` ("Later Person", `contact_later`,
`contact_again_after = current_date + 30`); job JB
`70000000-0000-0000-0000-000000000067` in Company B, `open`; job A =
`70000000-0000-0000-0000-000000000001` (the file's open A job); person "Zed
Hired" `20000000-0000-0000-0000-000000000067` with `personal_email
'zed@example.test'` and an active A period `30000000-0000-0000-0000-000000000067`
from `current_date - 100`; Omar's A grant temporarily gains **only**
`candidates.source` (the `omar_added` temp-table pattern, smoke.sql:3465;
removed at the tail) — a sourcer with no `candidates.view` anywhere, the
sharpest proof that the pool opens no company history. Actors: Alex
(`…0001`, A: `candidates.review` + `employment.edit`), Bea (`…0002`, B
Company HR), Omar (`…0003`), Ada (`…0004`, admin).

1. Seeds: the capability, its dependency, the Holding HR and Recruiter
   preset rows (not Company HR / Hiring Manager); 8 sources with the labels
   above; `applications_candidate_idx` exists; Cathy has `provider
   'manual'`, `source_key 'added_by_hand'`; the helper fixtures (the three
   phone forms, the two names, the LinkedIn slug, the masked email); P1's
   `phone_key = '70000067'`.
2. Alex: sees Cathy; `not exists` P1, P2, P3; a direct `insert into
   candidates (full_name)` → `insufficient_privilege`; the RPC without a
   job → 42501; a provider-keyed call → 42501.
3. Alex with job A and email `pool@example.test` (lower case) → `matches`
   with one row: `match 'email'`, `visible false`, `attachable true`,
   `email 'p***@example.test'`, `phone null`, `applications '[]'`, candidate
   count unchanged ("a match is offered without exposing the record and
   nothing is written"); with only `full_name 'Person Pool'` → `match
   'name'`, `attachable false`; `attach_to P1` with only the name → 42501;
   with the email → `attached`, an A application at `new` with
   `added_by_hand`, P1 now visible to Alex, `count(applications where
   candidate_id = P1) = 1`; the same call again → "already has an open
   application"; `ignore_matches` with `full_name 'Person Pool'`, `email
   'other@example.test'`, job A → `created`, `sourced_by = Alex`, `provider
   'manual'`. Then a superuser `insert into applications` for Cathy with
   `app.test_uid` still set (the 3739 shape) succeeds — the touch passes
   the guard.
4. Alex: `update candidates set phone = '+389 70 000 068' where id = P1` →
   1 row; `set source_key = 'head_hunt'` → 42501; `set do_not_contact =
   true, do_not_contact_reason = 'x'` → 42501; `set provider_ref = 'Z-9'`
   → 42501; `delete` → 0 rows.
5. Bea: `add_candidate_to_job(P1, JB)` → 42501 ("You cannot see that
   candidate."); a direct `insert into applications (job_id, company_id,
   candidate_id) values (JB, B, P2)` → `raise_exception '%asked not to be
   contacted again.%'` **without** the reason (Bea cannot see P2);
   `add_candidate_to_job(P1, job A)` → 42501 (review in the job's company).
6. Omar: `exists` P1, P2 and P3; `count(applications) = 0`;
   `search_candidates('{"q":"pool"}')` → P1 among rows; `{"q":"070 000
   068"}` → P1; `{"contact":"do_not_contact"}` → P2 and not P1 / P3;
   `{"contact":"wait"}` → P3 only of the three; `{"activity":"90d"}` → all
   three; `{"company_id": A}` → `total 0`; every row's `applications` is
   `[]`; `add_candidate_to_job(P1, job A)` → 42501 (a sourcer still needs
   review in the job's company); Bea and Alex → 42501 on `search_candidates`.
7. Omar: `upsert_sourced_candidate('manual', null, {"full_name":"New Pool",
   "email":"newpool@example.test","source_key":"head_hunt"})` → `created`,
   `sourced_by = Omar`, `provider_ref null`; `('linkedin_recruiter', 'LR-1',
   {"full_name":"Lin Ked","current_title":"Dev","created_at":
   "2024-03-01T00:00:00Z"})` → `created`, `created_at = 2024-03-01`,
   `last_activity_at = created_at`; again with `"current_title":"Senior Dev"`
   → same id, `updated`, title changed, `created_at` unchanged; the same
   email under `LR-2` → `created` and `possible_duplicates` names the
   first; `'manual'` with a ref → `invalid_parameter_value`;
   `{"full_name":"X"}` → 22023; `source_key 'nope'` → 22023.
8. Contact rule: Omar `set_contact_rule(P1, {"rule":"never"})` → 22023;
   `{"rule":"never","reason":"Asked us to stop"}` → `do_not_contact`,
   `do_not_contact_by = Omar`, `do_not_contact_at` set; Ada
   `add_candidate_to_job(P1, JB)` → "%asked not to be contacted again:
   Asked us to stop%"; Omar `{"rule":"later","contact_again_after":
   "<current_date + 10>"}` → flag cleared, `contact_later`; Ada
   `add_candidate_to_job(P3, job A)` → "%asked to be contacted after%"; with
   `p_override_wait := true` → an A application at `new` with `source_key
   'head_hunt'`; `{"rule":"ok"}` on P1 clears everything; Alex
   `set_contact_rule(P1, …)` → 42501.
9. Files: Omar inserts `candidate_files` for P2 (`storage_path
   'candidate/<P2>/g.pdf'`) and the object → ok; a row with `provider
   'zoho_recruit'` as Omar → 42501; a row for P2 with `storage_path
   'candidate/<P3>/x.pdf'` → `check_violation`; Alex reads objects under
   `candidate/<P1>/…` (P1 applied to A) and not P2's; Bea reads 0 pool
   objects and 0 `candidate_files`; `candidate/not-a-uuid/x.pdf` inserted
   as Omar → 42501 and as Alex → 42501 (not Ada: admins pass the 0013
   policies); Alex still inserts `'90000000-…-0001/f67.pdf'`
   (application-keyed objects unchanged); the bucket is still private.
10. Activity and audit (superuser): P1's `last_activity_at >=` the A
    application's `received_at`; an `application_events` note dated
    `2023-01-01` leaves it unchanged; `activity_log` rows with `entity_type
    'candidates'` for P1 have `company_id null`, carry `do_not_contact` in
    `after` and lack `email`, `phone`, `custom`; the number of candidate
    audit rows for P1 equals the guarded updates and RPC writes made (none
    from the touch alone).
11. Report: Alex's `recruitment_report(A, current_date - 1, current_date +
    1) -> 'sources'` contains "Added by hand" (the attached application)
    and "Head hunt" (P3's override application on job A).
12. Import (Ada): payload with `timezone_assumed 'Europe/Skopje'`; users
    `alex@a.test` (resolves) and `nobody@zoho.test` (unresolved); jobs ZJ-1
    (`company_code 'A'`, `filled`, `date_closed` given), ZJ-2 (`'A'`,
    `open`), ZJ-3 (`'A'`, `closed`, no `date_closed`, `modified_at` given);
    candidates ZT-1 (`linkedin_profile`, education rows in `custom`), ZT-2
    (`do_not_contact` + reason + `do_not_contact_at`, email
    `zed@example.test`), ZT-3 (no email, no phone); applications ZA-1 (ZT-1
    → ZJ-1, `screening`, `modified_at 2024-02-02`, `stale_closed`), ZA-2
    (ZT-2 → ZJ-1, `hired`, `hired_date current_date - 90`), ZA-3 (ZT-1 →
    ZJ-2, `screening`), ZA-4 (ZT-3 → ZJ-1, `hired`, no proposal expected),
    ZA-5 (ZT-3 → ZJ-3, `new`, `stale_closed`); one note on ZA-3 by Alex's
    Zoho user. Dry run → `committed false`, `counts.candidates_created 3`,
    `applications_created 5`, `stale_closed 2`, `hires[ZA-2].proposal.
    person_id = Zed` with `match 'email'`, `hires[ZA-4].proposal null`,
    `users.unresolved` 1, `count(candidates where provider = 'zoho_recruit')
    = 0`. Commit → ZA-1 `withdrawn`, `withdrawn_reason 'Job closed'`, two
    `stage_change` events (`null → screening` dated 2024-02-02, `screening
    → withdrawn` dated ZJ-1's `date_closed`); ZA-5 `withdrawn` with **one**
    event (`new → withdrawn`) dated ZJ-3's `modified_at` and
    `custom.zoho.close_date_assumed = true`; ZA-2 has an event
    `to_stage_key 'hired'` dated `current_date - 90` 00:00 UTC,
    `custom->'zoho'->'proposed_person'->>'id' = Zed`, `employment_period_id
    null`; ZA-3's note is an `application_events` row `kind 'note'` with
    `actor_id = Alex` and the `[Zoho …]` prefix; ZT-2 has `do_not_contact`
    with the payload's `do_not_contact_at`; ZT-1's `last_activity_at`
    equals the payload's; commit again → `candidates_skipped 3`,
    `applications_skipped 5`, no new rows; `company_code 'ZZ'` with
    `p_commit true` → `raise_exception '%refused%'` and nothing written;
    Alex → 42501.
13. Link: Alex `link_hired_application(<ZA-2>, Zed)` → `employment_period_id
    = …000067`, a `note` event; again → "%already linked%";
    `link_hired_application(<ZA-3>, Zed)` → "%Only hired applications%";
    Bea → 42501 (ZJ-1 is in A); Ada `link_hired_application(<ZA-4>, null)`
    → `linked false`, `proposed_person` null.
14. Tail: Omar's added capability removed via the temp table; `set
    app.test_uid = ''`.

### 2.2 Unit

`app/src/lib/candidatePool.test.ts`: the key mirrors with the SQL fixtures;
`longDate`; the sentences verbatim for every match kind and both
visibilities; `contactState` / `contactBadge` around a fixed today; the
filters ↔ query round-trip. `app/src/lib/candidateFiles.test.ts`:
`candidateFileObjectPath`, `extensionFor`, `CANDIDATE_FILE_KINDS`.
`server/src/zohoRecruit/*.test.ts` (`cd server && npm test`): every one of
the 38 status strings maps and an unknown one throws; the 10 source values
map and an unknown one throws; the department map; the four date shapes in
Europe/Skopje; the mention rewrite; MK phone forms; NFC name equality
(`Möllersten` NFD vs NFC); education rows incl. the `Jan-1` sentinel; the
name fallback; malformed email → `custom.links.raw_email`; the two contact
flags (51 / 54); the job status map; the stale rule incl. the Cancelled
fallback date; attachment classification incl. the `" bytes"` suffix;
`htmlToText`; the 3-row synthetic fixture folder runs the extractor end to
end.

### 2.3 E2E (Playwright, live project, `E2E` prefixes; cleanup before / after
incl. `candidate/<id>/` objects and `candidate_files`)

- **`app/e2e/talent-pool.spec.ts`** — seed (service client) two open SNOW
  jobs "E2E Pool Role A/B" → admin → `/hiring?tab=pool` → `pool-add` ("E2E
  Pool Person", `e2e-pool@example.test`, a LinkedIn address, Head hunt) →
  the record opens → Files: upload the one-page PDF → DB
  `candidate_files.storage_path` starts with `candidate/` → Add to job →
  "E2E Pool Role A" → the application page → DB: one application,
  `source_key 'head_hunt'`, `stage_key 'new'` → back to the pool, search
  "E2E Pool" → `pool-row-<id>` shows "1 · latest: E2E Pool Role A" →
  Contact rule → Never, reason "E2E: asked to stop" → DB `do_not_contact`,
  `do_not_contact_by` = the admin's person → job B → `source-from-pool` →
  the row shows *Do not contact* and no `pool-pick-<id>`.
- **`app/e2e/pool-dedupe.spec.ts`** — seed a pool candidate (`provider
  'e2e'`, ref `pool-1`, email X) with a rejected application on job A →
  job B → Add candidate with email X → `candidate-matches` shows "This
  looks like E2E Pool Person (same email)." → `match-attach-<id>` → DB: a
  B application, still exactly one `candidates` row with email X → Upload
  CVs with a file named after the same person and email X → the row shows
  the choice → Create a new candidate anyway → a second candidate exists
  with the CV in `candidate_files` → the application page lists it under
  "Candidate's files".
- **`app/e2e/upload-cvs.spec.ts`**: the DB assertion at `:101-114` reads
  `candidate:candidates(full_name, email, candidate_files(kind,
  original_name))` instead of `application_files`; cleanup adds the rows
  and the `candidate/<candidateId>/` objects. `careers`, `hiring-pipeline`,
  `job-workspace`, `candidate-review`, `reports`, `home*` unchanged
  (checked: service-client seeds, "Save candidate" with unique names,
  `ready` / `open` jobs).

## 3. The Zoho import

The CSVs are at `docs/Data_001/Data/*.csv`, the files at
`docs/Attachments_001/` (file names `<attachment id>_<original name>`;
`File Name` in `Attachments_001.csv` matches 2,824 of 2,825).

### 3.1 Mapping — `server/src/zohoRecruit/mapping.ts` (tested)

**Status → stage.** The keys are the 38 distinct `Candidate Status` values
of `Associated_001.csv`, byte-exact (ASCII hyphens, case — both "Not
Contacted" and "Not contacted" exist); an unknown status is a problem,
never a guess:

| stage | Zoho statuses (→ reason / flag) |
|---|---|
| `screening` | Contacted · Interested · Qualified · Waiting-for-Evaluation |
| `new` | Associated · New · Attempted to Contact · Not Contacted · Not contacted |
| `withdrawn` | Not Interested ("Not interested") · Not responding ("No response") · Withdraw Application ("Candidate withdrew") · NEVER to be contacted again ("Do not contact" + `do_not_contact`) · Contact in Future ("Contact in future" + `contact_later`) · Offer-Declined ("Offer declined") |
| `rejected` | Rejected ("Rejected") · Rejected by hiring manager ("Rejected by the hiring manager") · Rejected by HR ("Rejected by HR") · Rejected by Manager - Interview ("Rejected by the manager after interview") · Rejected-for-Interview ("Rejected for interview") · Unqualified ("Unqualified") · Offer-Withdrawn ("Offer withdrawn") · Rejected-Hirable ("Rejected, hirable later" + `contact_later`) |
| `interview` | On-Hold · Interview 1 - HR · Interview 2 - Stakeholders · Interview 3 - Other stakeholder · Interview 4 - Other stakeholders · Feedback to be provided from an Interview · Interview-Scheduled · Interview-to-be-Scheduled · Interview-in-Progress · Submitted-to-hiring manager · Task · No-Show |
| `offer` | Offer-Made · To-be-Offered |
| `hired` | Hired |

(Who rejected is the reason text — Zoho's own reason field is empty on all
3,611.)

**Source → `source_key`** — total over the 10 distinct `Source` values of
`Candidates_001.csv`; an unknown source is a problem: Head Hunt →
`head_hunt`; Imported using Resume Extractor → `linkedin_profile`;
Advertisement Linkedin → `linkedin_ad`; CareerSite → `careers_page`;
Advertisement External Career Pages → `job_board`; Advertisement →
`job_board`; Employee Referral → `referral`; External Referral → `referral`
(the kind kept in `custom.zoho.source`); Added by User → `added_by_hand`;
None or blank → `imported`.

**Department → company** per D1 (`DEPARTMENT_TO_COMPANY`, Clip Media Group
→ null). **Job status**: Filled → `filled`, Cancelled → `closed`,
In-progress → `open`, Inactive → `on_hold`. **`staleRule(stage_key,
jobStatus)`**: a non-terminal mapped stage on a Filled / Cancelled job →
`withdrawn`, `withdrawn_reason 'Job closed'`, `stale_closed true`; the close
date = `Date Closed` else the job's `Modified Time` (+
`close_date_assumed`). `rewriteMentions(body, users)`
(`recruit[user#…#id]recruit` → `@Full Name`); `notePrefix(type, date,
actor)` → `[Zoho Call · 12 Mar 2024 · Kristina Arsova]`.

**Dates** (`dates.ts`, wall clock in `Europe/Skopje`, invalid → null + a
problem): four shapes — `MM/DD/YYYY hh:mm AM` (**month first**: candidates,
notes, attachments, job Created Time), `YYYY-MM-DD HH:MM:SS.0`
(associations), `MM/DD/YYYY` (job Date Opened / Date Closed), `YYYY-MM-DD`
(Hired Date). A fixture per shape.

**Columns → fields** (`payload.ts`; the review file prints the map):

| payload field | `Candidates_001.csv` column |
|---|---|
| `zoho_id` / `display_id` | `Candidate Id` (Zrecruit_…) / `Candidate ID` (ZR_…_CAND) |
| `full_name` | `Full Name` → `First Name` + `Last Name` → `Last Name` → display id |
| `email` | `Email` (malformed → `custom.links.raw_email`); `Secondary Email` → `custom.links.secondary_email` |
| `phone` | `coalesce(Mobile, Phone)` (never both; the other → `custom.links`) |
| `linkedin_url` | `LinkedIn` |
| `current_title` / `current_employer` | `Current Job Title` / `Current Employer` |
| `location` | `City`, `Country` joined with ", " |
| `skills` | `Skill Set` split on "," and trimmed |
| `summary` | `Profile Summary`, else `Additional Info` |
| `referred_by` | `Referred by Employee` |
| `source_key` | `Source` through the map |
| `owner_zoho_id` | `Candidate Owner ID` |
| `created_at` / `updated_at` / `last_activity_at` | `Created Time` / `Modified Time` / `Last Activity Time` (fallback `Modified Time`) |
| `custom.zoho` | every Zoho fact verbatim: `id, display_id, status, stage, source, owner_name, created_by_name, rating, is_locked, fresh_candidate, experience_years, expected_salary / current_salary (only when > 0), tags` |
| `custom.education[]` | `Candidates_Educational_Details.csv` rows in file order: `{ institute, major, degree, from, to, current, zoho_row_id }`; dates are `Mon-YYYY` → `YYYY-MM`; a year below 1900 (the 457 `Jan-1` sentinels) → null |

Jobs (`Job Openings_001.csv`): `Job Opening Id` → `zoho_id`, `Job Opening
ID` → `display_id`, `Posting Title` (else `Title`) → `title`, `Job
Description` → `description`, `Job Opening Status` → status, `Department
ID` → company through `Departments_001.csv`, `Created Time`, `Date
Closed`, `Modified Time`; `custom.zoho = { id, display_id, department,
hiring_manager_email, recruiters, target_date, date_opened, date_closed,
headcount, close_date_assumed }`. Users (`Users_001.csv`): `User ID`,
`Email`, `First Name` + `Last Name`.

**Contact flags.** `do_not_contact` = candidate-level NEVER ∪
association-level NEVER (51 people); `do_not_contact_at` = that
association's `Modified Time`; `do_not_contact_by_zoho_id` = its `Modified
By`; the reason = the latest Change Status / Unassociation / Notes body on
that candidate within 7 days of it (≤ 300 chars), else "Zoho Recruit: NEVER
to be contacted again (set by <name> on <DD Mon YYYY>)". `contact_later`
from **association** statuses only (Contact in Future ∪ Rejected-Hirable,
54); a candidate-level Contact in Future / Rejected-Hirable with no such
association (5 people) stays in `custom.zoho.status` only; no date.

**Applications** from `Associated_001.csv` (`Associated Id`, `Candidate
ID`, `Job Opening ID`, `Candidate Status`, `Stage`, `Created Time`,
`Modified Time`, `Modified By`, `Hired By`, `Hired Date`); the
candidate-level status of the 400 never-associated candidates is only
stored in `custom.zoho.status`. **Notes** (`Notes_001.csv`, per D7): a note
whose `Candidate Id` + `Job Opening Id` pair is an imported association;
Interviews-module notes resolve their pair through `Interviews_001.csv`
(`Candidate ID` / `Job Opening ID` of the parent interview); Job Openings-
and Tasks-module notes (36) are skipped and counted; candidate-level notes
(1,758) are counted under `notes_without_application`.

**Files** (`files.ts`): `classifyAttachment(row, diskStat)` → `{
candidateZohoId | null, kind, reason?, textOnly }`: `Zrecruit_Resume` →
`cv` for pdf / doc / docx / jpg / png, `.html` → `profile` text-only;
`Zrecruit_Cover Letter` → `cover_letter`; `Zrecruit_Others` / `Zrecruit_Offer`
→ `other` (Offer keeps `custom.zoho.category = 'Offer'`); a blank category
with a note parent → resolved through the note's candidate (`cv` when the
name says CV, else `other`); `Zrecruit_ICS`, `Zrecruit_Job Summary`, xlsx,
msg, rar, job- or interview-parented, over 10 MB → `skip` with the reason.
Size from disk (797 CSV sizes are wrong once the one `" bytes"` suffix is
stripped); NFC on both sides of the name match; `htmlToText` strips tags
and entities, collapses whitespace, caps at 100 kB. The 2,496 resume rows
cover 2,496 candidates; 1,181 of them are HTML captures.

### 3.2 Extract — `server/scripts/zoho-recruit-extract.ts`

`npx tsx server/scripts/zoho-recruit-extract.ts docs/Data_001/Data
docs/Attachments_001 --tz Europe/Skopje --out .zoho-payload.json --files
.zoho-files.json --review .zoho-review.json` (the npm script runs exactly
this). Pure: no database, no secrets. Writes the §3.3 payload, the files
manifest `[{ attachment_id, candidate_zoho_id, kind, path, original_name,
mime, size_bytes, created_at, text_only }]` for eligible files, and the
review file: same-LinkedIn groups (37 by `linkedin_key`, 35 by exact URL),
same-name groups split by LinkedIn, the 400 never-associated candidates,
the 1,332 stale applications, unknown statuses / sources (must be 0),
hires with their CSV facts, unresolvable files, the column map. Prints
counts only: candidates, applications per stage (and stale),
do-not-contact, contact-later, jobs per company code, unresolved
departments, notes attached / left, files eligible / text-only / skipped
by reason, `timezone_assumed`. Exits 1 on an unknown status or source.

### 3.3 `import_zoho_recruit` — payload, passes, report

**Payload**: `{ exported_at, timezone_assumed, users: [{ zoho_id, email,
name }], jobs: [{ zoho_id, display_id, company_code, title, description,
status, created_at, modified_at, date_closed, custom }], candidates: [{
zoho_id, display_id, full_name, email, phone, linkedin_url, source_key,
current_title, current_employer, location, skills, summary, referred_by,
owner_zoho_id, created_at, updated_at, last_activity_at, do_not_contact,
do_not_contact_reason, do_not_contact_at, do_not_contact_by_zoho_id,
contact_later, custom }], applications: [{ zoho_id, candidate_zoho_id,
job_zoho_id, stage_key, stale_closed, close_date, close_date_assumed,
zoho_status, zoho_stage, withdrawn_reason, rejected_reason, received_at,
modified_at, modified_by_zoho_id, hired_date, hired_by_zoho_id, custom }],
notes: [{ zoho_id, application_zoho_id, kind, body, actor_zoho_id,
actor_name, created_at }] }`.

**Pass 1** (decide; jsonb dictionaries like 0028): companies by
`short_code` (unarchived) for every distinct `company_code` — a missing
code refuses every job carrying it; users → `people` by
`lower(work_email)` (unarchived; the generic hr@ / admin@ accounts never
map), unresolved kept by name; jobs: title 2..200, status inside the `jobs`
CHECK, existing when `custom->'zoho'->>'id'` matches → skipped, else
created (a dry run assigns `gen_random_uuid()` placeholders so applications
resolve); candidates: `candidate_payload_problems(row)` (refuse on any
problem), `do_not_contact` needs a reason, existing `(zoho_recruit,
zoho_id)` → skipped, **possible duplicates** against non-Zoho rows (email
`::citext` → phone key → LinkedIn key → name key) reported as `[{ zoho_ref,
full_name, existing_id, existing_name, match }]`, never merged;
applications: refs resolve inside the payload, `stage_key` in
`application_stages`, existing `(job_id, 'zoho_recruit', zoho_id)` →
skipped, a withdrawn / rejected row carries its reason; notes: the
application must resolve; hires: for each `stage_key = 'hired'` propose a
person — `people.personal_email` or `work_email = email::citext` →
`'email'`; else `app.phone_key(people.phone) = app.phone_key(phone)` →
`'phone'`; else `app.name_key(people.full_name) = app.name_key(full_name)`
**and** an `employment_periods` row in the job's company → `'name'`; else
null.

**Pass 2** (commit only): `jobs` (explicit `created_at`, `custom.zoho`);
`candidates` (`provider 'zoho_recruit'`, `provider_ref`, `source_key`,
`sourced_by` = the resolved owner, `created_at / updated_at /
last_activity_at` from Zoho, the contact columns as given with
`do_not_contact_by` resolved or null); `applications` inserted **directly
at their final stage** (`withdrawn` when `stale_closed` — imported rows
never pass through the touch trigger's update path), `source_key` = the
candidate's, `source_provider 'zoho_recruit'`, `provider_ref = zoho_id`,
`received_at / created_at` = Zoho created time, `owner_id` = the resolved
modifier, the reasons, `custom.zoho = { associated_id, status, stage,
created_by, modified_by, modified_time, hired_by, hired_date,
close_date_assumed }` plus `custom.zoho.proposed_person = { id, full_name,
match }` for hires; `application_events`: one `stage_change null → <mapped>`
per application whose mapped stage is not `new` (`body 'Imported from Zoho
Recruit: "<zoho_status>".'`, `actor_id` = the resolved modifier or null,
`created_at = modified_at`; hires at `hired_date` 00:00 UTC, so
`recruitment_report` counts them on their true dates), a second
`<mapped> → withdrawn` for stale rows (`body 'Imported from Zoho Recruit:
the job was <filled|cancelled> while this application was
"<zoho_status>".'`, `created_at = close_date`) — stale rows mapped to
`new` get that single event; one `note` per payload note (`body = prefix
|| rewritten body`, `actor_id` resolved or null, `created_at` = the note's
time). Verification, then the `activity_log` row. Expected volume: ~3,200
+ ~1,330 + ~1,210 ≈ 5,750 events.

**Report**: `{ committed, counts: { jobs_created, jobs_skipped,
candidates_created, candidates_skipped, applications_created,
applications_skipped, stale_closed, events_created, notes_created,
users_resolved, users_unresolved, refused, do_not_contact, contact_later,
possible_duplicates }, users: { resolved, unresolved }, rows: [refused only:
{ kind, ref, problems[] }], hires: [{ application_id, candidate, job,
company, hired_date, proposal: { person_id, full_name, match } | null }],
possible_duplicates, assumptions: [timezone, department mappings,
synthesised reasons, assumed close dates] }`.

**`scripts/zoho-import.sh --dry-run|--commit [payload.json]`** — a copy of
`scripts/fn-import.sh` calling `public.import_zoho_recruit` (dollar-quoted
`$zohopayload$`, the admin through `request.jwt.claim.sub` /
`request.jwt.claims`, `PGCLIENTENCODING=UTF8`, output to
`<payload>.report.json`) whose python summary prints counts, refused rows,
unresolved users, possible duplicates and the hires table (candidate · job
· company · hired date · proposal · match). Nothing from `.env.local` is
printed.

### 3.4 Files — `server/scripts/zoho-recruit-files.ts --dry-run|--commit [.zoho-files.json]`

After a committed row import. `createClient(SUPABASE_URL,
SUPABASE_SECRET_KEY)` from `.env.local` (the `import-popis-xlsx.ts`
pattern). Loads the `zoho_recruit` candidate id map once and the existing
`candidate_files.provider_ref` set. Per manifest row: skip when the ref
exists (idempotent) or the candidate is unknown (reported); the row `id` is
generated first; text-only → the stripped text uploaded as `text/plain` at
`candidate/<id>/<file_id>.txt` (`kind 'profile'`, `original_name 'LinkedIn
profile capture (<DD Mon YYYY>).txt'`, `extracted_text` = the same text);
stored files → upload `candidate/<candidate_id>/<file_id>.<ext>` with
`contentType`, then insert `candidate_files { id, candidate_id, kind,
storage_path, original_name (after the 17-digit prefix, NFC, ≤ 200),
mime_type, size_bytes (disk), uploaded_by (resolved owner or null),
provider 'zoho_recruit', provider_ref, created_at }`; on row failure remove
the object. Concurrency 4; prints uploaded / skipped / failed and the
failures list. ~2,700 uploads take about 20 minutes.

### 3.5 Run order on live (after §4 step 9)

1. Apply every pending migration through 0067 to live (check `select
   max(version)` first — the handoff records live at 0044 while 0045–0066
   are on main); deploy the app. The admin grants `candidates.source` to
   the Holding HR people from the access editor.
2. D8: delete the leftover test application and its candidate.
3. Extract; read the printed counts and the review file.
4. `scripts/zoho-import.sh --dry-run` → refused rows must be 0; read
   unresolved users, possible duplicates and the hires table with the
   maintainer.
5. `scripts/zoho-import.sh --commit` (all or nothing).
6. Files: `--dry-run`, then `--commit`.
7. Re-run 4 and 6 once to prove idempotence (everything skipped). Open the
   pool as Ivana and spot-check five records. HR confirms the hires from
   each application page.

## 4. Order of work (each step green before the next)

1. Migration 0067 (§1.1) + smoke block (§2.1) →
   `supabase/tests/local-verify.sh` green.
2. `database.ts`.
3. `lib/candidatePool.ts`, `lib/candidateFiles.ts`, `extensionFor`,
   `friendlyRecruitmentError` + tests; `npx vitest run`.
4. `CandidateMatches.vue`; the two add dialogs on the RPC; `JobPage`
   Source from pool + `PickFromPoolDialog`; the `upload-cvs` assertion;
   `npx vue-tsc --noEmit -p tsconfig.json`.
5. `TalentPoolPanel` + tab; `CandidatePage`, `CandidateFilesCard`,
   `ContactRuleDialog`, `SourceToJobDialog`, router.
6. `ApplicationPage` (via, badge, candidate files, `ImportedHireCard`);
   `ApplicantsPanel` / `HomePage` scoping; `careersRoutes.ts` keys.
7. `talent-pool.spec.ts`, `pool-dedupe.spec.ts`; the recruitment specs.
8. Zoho code: mapping modules + tests → extract against the real export
   (counts only) → dry run against the **local** database (local-verify
   stack) → fix until refused = 0. No live writes in this step.
9. Docs and rows (§1.4); `/code-review medium`; fix findings; commit
   `feat: the talent pool — candidates the holding can find again`
   (explicit paths).
10. The live sequence of §3.5.

## 5. Seams left on purpose

- **Outreach sub-statuses (next slice)**: every imported application keeps
  `custom.zoho.status` / `.stage` verbatim (the 38 values are the
  vocabulary; the constant in `mapping.ts` is where their sub-status column
  will be added); `app.open_application` is the single birthplace of a
  sourced application where an initial sub-status (`sourced`) is set in one
  line; `application_stages` and the events CHECK are untouched (that slice
  adds `application_sub_statuses (stage_key, key, label)` +
  `applications.sub_status_key` and widens the CHECK for `outreach`);
  `last_activity_at` and the activity filter are where "not responding for
  30 days" reads from; the match hint already carries the contact rule.
- **Candidate-level notes**: the 1,758 candidate-level (1,557 job-less +
  201 whose pair is no imported association) and 36 job- / task-module Zoho
  notes are counted, not imported; the table to add is `candidate_notes
  (candidate_id, company_id null = about the person / set = that company's
  history, kind, body, actor_id, actor_name, occurred_at, provider,
  provider_ref)` read by pool holders or `candidates.view` in the tagged
  company — never "any company with an application" — plus a Notes card on
  the record; `custom.zoho.associated_id` and `provider_ref` let that import
  attach by id.
- **LinkedIn Recruiter / CSV**: `upsert_sourced_candidate('linkedin_recruiter',
  <profile ref>, payload)` per row with `source_key 'head_hunt'` or
  `'linkedin_profile'` and `created_at` honoured; `candidate_files
  (provider, provider_ref)` for attachments; the extract → dry run → commit
  shape of §3 with a new mapping module. No change to `providers`,
  `channels` or the two existing LinkedIn provider rows.
- **Interviews / reviews from Zoho** (104 / 75): the preserved ids let a
  follow-up pass add `interviews` / `scorecards` once reviewer people rows
  are decided. **Retention**: `archived_at`, `last_activity_at`,
  `do_not_contact` are the inputs of a later rule; no purge in 052.
  **Careers CVs to the candidate**: `candidate_files.provider = 'careers'`
  is ready. **Search over profile text**: `extracted_text` is filled for
  the 1,181 captures; a tsvector index and a `q_text` parameter come later.

## 6. Risks

1. The 0006 fallback disappears; any client `candidates.insert` stops
   working — both dialogs move in the same slice, the careers route is
   service-role, smoke 2 makes a regression loud; a local script of the
   maintainer's that inserts as a signed-in user would be affected.
2. `candidates.source` shows every identity row holding-wide (name,
   contact, `custom` incl. education); company histories stay scoped
   (smoke 6); the label says "holding-wide" and the docs say it.
3. Cross-company identity row (pre-existing, now wider): a B reviewer with
   a B application may edit the shared name / contact / profile of a
   candidate A also talked to (D5); the pool fields and the contact rule
   are guarded. Documented in `data-model.md`.
4. Existence disclosure by design: a reviewer typing an email / name learns
   "already in the talent pool" with the stored name and a masked email —
   the minimum that prevents silent duplicates; history stays hidden
   (blueprint §5).
5. A second storage-path convention: three policies beside 0013's; the
   resolver returns null for anything malformed and `can_*_candidate(null)`
   is false; smoke 9 proves both shapes (and that admins pass the 0013
   policies).
6. A CV uploaded through Upload CVs is readable wherever that person
   applied; job-specific material still goes to `application_files`; the
   card heading says so.
7. `t0_guard_contact` on every `applications` insert: one indexed lookup;
   the careers route (service role) and the import (flag) pass; smoke 5.
   The flag discipline (outermost setter, restore the previous value) is
   what keeps nested writes working; smoke 3 exercises upsert → attach →
   a later write in the same call.
8. Import volume: ~8,000 rows + ~11,000 audit rows + ~5,750 events in one
   transaction, a 10–15 MB payload through psql (the 0028 precedent); dry
   run first; ~2,700 object uploads take about 20 minutes.
9. After the import the 8 open Zoho jobs carry hundreds of
   sourced-never-contacted applications: `recruitment_report.attention.
   stale / unassigned` rise honestly; Home is scoped to live roles and the
   Applicants tab to 1,000 rows; any other page that later loads
   applications unbounded inherits the 1,000-row cap silently; the
   outreach slice is what makes that state workable.
10. Stale applications closed as withdrawn "Job closed" (1,332): truthful
    to what happened; the Zoho status is kept as the first event (when not
    `new`) and in `custom.zoho.status`; the alternative is one line in
    `staleRule`.
11. Zoho data quality: 2,832 candidates have neither email nor phone;
    name-only matches are suggestions and say so; the 37 same-LinkedIn
    groups import as separate rows and are listed for HR (never merged);
    hire matching is weak by nature (19 of 59 hired candidates have an
    email, all personal) — proposals only, confirmed by HR; the export is a
    snapshot of 2026-09-21 and a second export runs the same cycle.
12. PII on disk: `docs/Data_001/`, `docs/Attachments_001/` are git-ignored
    (the pending hunk); the payload / manifest / review / report patterns
    are added; `docs/files 1/` is the maintainer's and is never staged; the
    scripts print counts and the hires table only.
13. The generated-column helpers rely on `lower()` / `translate()` /
    `regexp_*` being immutable under the default collation; a
    non-deterministic ICU collation on live means an expression index
    instead of a generated column (same semantics, one-line change).
14. Report labels: `recruitment_report` re-declared with two lines changed;
    smoke 11 and `reports.spec.ts` guard it. No grant backfill: until the
    admin grants `candidates.source`, only platform admins see the pool —
    one step in the run order.

## 7. Files

**Create**: `supabase/migrations/0067_talent_pool.sql`;
`app/src/lib/candidatePool.ts` + test, `app/src/lib/candidateFiles.ts` +
test; `app/src/components/CandidateMatches.vue`, `SourceToJobDialog.vue`,
`PickFromPoolDialog.vue`, `CandidateFilesCard.vue`, `ContactRuleDialog.vue`,
`ImportedHireCard.vue`, `hiring/TalentPoolPanel.vue`;
`app/src/pages/CandidatePage.vue`; `app/e2e/talent-pool.spec.ts`,
`app/e2e/pool-dedupe.spec.ts`; `server/src/zohoRecruit/{csv,dates,mapping,
payload,files}.ts` + tests + `fixtures/`, `server/scripts/zoho-recruit-extract.ts`,
`server/scripts/zoho-recruit-files.ts`; `scripts/zoho-import.sh`.

**Change**: `supabase/tests/smoke.sql`; `app/src/types/database.ts`;
`app/src/lib/applicationFiles.ts` (`extensionFor`), `jobWorkspace.ts`;
`AddCandidateDialog.vue`, `UploadCvsDialog.vue`, `ApplicationFilesCard.vue`
(heading), `hiring/ApplicantsPanel.vue`; `JobPage.vue`,
`ApplicationPage.vue`, `HiringRequestsPage.vue`, `HomePage.vue`;
`app/src/router/index.ts`; `app/e2e/upload-cvs.spec.ts`;
`server/src/careersRoutes.ts`, `server/package.json`; `.gitignore`;
`docs/data-model.md`, `docs/integrations-zoho.md`,
`docs/development-plan.md`, `docs/session-handoff.yaml`, `plans/README.md`.

## 8. Out of scope

Outreach sub-statuses inside Screening (own slice, seams above).
`candidate_notes` and the candidate-level Zoho notes, interviews, reviews
(a follow-up import pass). A dashboard tile for the pool. A retention /
anonymisation rule (the maintainer's legal call). Moving careers CVs to the
candidate. A service-role path in `upsert_sourced_candidate` for the
careers route (it keeps its inserts and its email-reuse rule). Text
extraction from uploaded CVs (plan 020). Backfilling `candidates.source`
onto existing grants. The LinkedIn Recruiter import itself (the door
exists).
