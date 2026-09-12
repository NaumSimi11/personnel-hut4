# Personnel: development plan

Working plan for the real build (Vue app + Supabase). Derives its order from
[the blueprint's build sequence](hr-system-blueprint.md) (§9); the design
prototype in `../prototype` is the UI spec. Updated as milestones land.

## Done

| Milestone | Where | Proof |
|---|---|---|
| Design prototype round 02 (view-as, self-service, queue, projects) | `prototype/`, branch `advisor/007-projects-read-only-panel` | 12 Playwright tests |
| Data model: 52 tables, RLS everywhere, seeds, transition gates | `supabase/migrations/0001–0008`, live on eu-west-2 | `supabase/tests/local-verify.sh` + adversarial review |
| Bootstrap: Hut4 + 4 companies, first platform admin | live DB | authenticated RLS read-back |
| App slice 1: login, directory, access editor | `app/` | 5 unit + E2E |
| Auth flow: invite-only, one-time temp password, forced first-login change, reset-as-reinvite (ported from the leave system) | `server/`, `shared/passwordPolicy.ts`, migration 0008 | 4 E2E incl. full invite lifecycle |
| Employee records foundation (core): add person (record ≠ account), first employment, profile page with employment history + access summary, end employment | `app/` (AddPersonDialog, PersonProfilePage) | E2E add→directory→profile→end |
| Records depth: invite attaches to an existing record (never duplicates), private personal details card | plan 008 | E2E attach + details persist |
| Hiring workspace A: requests, approve / request changes / reject with DB-enforced no-self-approval | plan 009 | E2E incl. self-approval refusal |
| Hiring workspace B: jobs from approved requests, candidates, stages, atomic idempotent confirm hire | plan 010 + migration 0009 | E2E request→job→candidate→hire→employee |
| Onboarding: queue with readiness, plan detail, complete/reopen/block/skip, finish plan | plan 011 | E2E block→complete→ready→finish |
| Home: needs-action queue (approvals, offers, readiness gaps), metrics, my tasks; post-login landing | plan 012 | E2E queue rows + deep links |
| Self-service: My workspace — own profile and employment history, own onboarding (read-only), tasks assigned to me, my access per company, my synced projects | plan 013 | E2E own-task complete + admin note |
| Company profiles: holding list with headcounts; per-company tabs (overview, people, access, hiring, projects, integrations), deep-linkable | plan 014 | E2E all tabs + `?tab=` deep link |
| Zoho Projects read-only sync: OAuth client, per-company mapping with routing exceptions, idempotent mirror upserts, CLI with dry-run ([docs](integrations-zoho.md)) | plan 015 | 15 tests incl. live-DB sync with a fixture client; awaiting Zoho credentials to go live |
| Company management: admins create / edit / archive companies with a full profile — logo (public Storage bucket), accent colour, tagline, website, legal & registration, director / HR contact; archive is the only delete and every picker honours it | migration 0011, `CompanyFormPage` | E2E create with logo → profile → edit → archive → gone from pickers; schema smoke tests |
| Offboarding: schedule departure (dates + restricted reason → plan), queue with blockers, kind-aware plan page, explicit "mark as former" allowed with open tasks; Departing badge; `auth.can()` capability hint for non-admin HR | migration 0010 + plan 016 | E2E schedule → queue → task → former; smoke tests for the RPCs |
| Job workspace: five-step journey, tabs (Overview · Description + screening questions · Channels · Applications · Promotion · Activity), draft → ready → open lifecycle, careers publish / manual posting records / out-of-date flag, promotion as a separated-duties state machine (`advance_promotion`), recruitment audit trail | migration 0012 + plan 017 | E2E prepare → describe → publish → promote → applications → activity; smoke tests for transitions, self-review refusal, re-request |
| Candidate page: files in a private bucket behind signed links (`application_files`, company derived server-side), screening answers, timeline + notes, decision panel (owner / next action / due), reasoned reject & withdraw, stage moves guarded against stale views | migration 0013 + plan 018a | E2E upload → unsigned read refused → signed read OK → answers → decision → note → reject; smoke tests for company derivation, RLS, private bucket, junk-object safety |
| Interviews with a panel; blind scorecards (1–4 + evidence per criterion, recommendation) hidden from panel members until they submit, enforced in RLS; scorecard criteria per job; offer state machine (`advance_offer`: draft → in approval → approved by someone else → extended → accepted / declined, withdraw any time; author server-set and immutable); Confirm hire takes the accepted start date; job Interviews & Offer tab | migration 0014 + plan 018b | E2E schedule → hidden colleague card → submit → both visible → offer → self-approval blocked → withdraw → colleague's offer approved → extended → accepted → hired with agreed date; smoke tests for blind rule, forged author/company, transitions |
| Public careers page + intake: branded per-company listing and application form (CV, screening answers, consent) through the auth service only; honeypot, per-IP and per-email limits, exact code lookup, server-side answer checks, one open application per person per role | plan 019 | E2E anonymous apply → reference → duplicate refused → honeypot dropped → recruiter sees file, answers, source; 15 server unit tests |
| Recruitment reporting: per-company KPIs, funnel by job, source attribution, attention counts — counted in the database (`recruitment_report`, jobs.view), CSV export | migration 0015 + plan 021 | E2E seeded stages → KPIs, funnel, sources, attention, CSV; smoke tests for numbers and refusal |
| Employment changes: dated title / department / location / manager / type changes with reason; immediate or scheduled, applied when due, guards re-run at apply time (cycle, company scoping, ended employment → failed with reason); Structure tab (departments, locations); directory state + company filters | migration 0016 + plan 022 | E2E structure → immediate change → scheduled + cancel → cycle refused → filters; smoke tests incl. apply-time cycle and former-cancels-pending |
| Compensation: one amount + currency + pay basis per record; proposed by one person, decided by another (`salary.propose` / `salary.approve`), approving closes the previous approved record the day before so history never overlaps; refused after a departure; Payroll tab totals annualised per currency with distinct active headcount (`payroll.summary`) | migration 0017 + plan 023 | E2E current → propose → no self-approval → colleague approves → history → payroll total matches independent sum → own compensation; smoke tests for gating, self-approval, direct-write refusal, supersede, departure edges |
| Company operations: Upcoming starters / departures on the company overview, workflow owners per role on a Settings tab (Unassigned never skips approval), submitted hiring requests name the configured approver, invite from the company Access tab | plan 024 | E2E upcoming → owner saved → request names approver → invite dialog; unit tests |
| Hardening: audit log redacts blind scorecards, compensation amounts and offer terms (existing rows too); reporting-loop guard walks within the company; deferred employment changes re-run every guard; one open application per candidate per job; careers per-email budget spent only after a saved application, serialised per email | migration 0018 + plan 025 | smoke assertions per rule; server unit tests; full suite |
| Documents: employee and company documents with categories, versions (a new version archives the old, lineage frozen), visibility hr_only / person_and_hr / company_public, private bucket read only through a visible row, short-lived links; profile card, My documents, company Documents tab | migration 0019 + plan 026 | E2E upload → signed link → new version → archived history → company document; smoke for provenance, scope, versioning, storage policies |
| Hardening 2: offers/promotions always start in their initial state; a future raise keeps the current record approved until the day before; due changes apply for editors and nightly via pg_cron; direct manager edits cannot loop; candidate file audit redacted; careers submissions roll back on CV failure, limits answer in contract | migration 0020 + plan 027 | smoke per rule; server unit tests; full suite |
| Document requests: HR asks for a document with due date and note; the person uploads it from My workspace (only while a request is open; always person_and_hr) and HR accepts or sends it back. Policies: per company or holding-wide, drafts publish with a file, a new version needs a new file and resets acknowledgements, each person acknowledges the version read; counts on the company Documents tab | migration 0021 + plan 028 | E2E HR request → employee signs in and submits → accepted; publish → acknowledge → count; smoke for pinning, window, review, versions, storage |
| Equipment & IT: assets per company (tag, type, model, serial, location) with status derived from handovers — reserve for a person, issue, return with condition and next status, cancel a reservation; IT requests for a person with systems and due date, worked open → in progress → blocked (reason) → done by it.assign / it.complete; holders see their own equipment | migration 0022 + plan 029 | E2E asset → reserve → issue → profile → return damaged; request → start → done; smoke for status sync, employment check, gates, pinning |
| Activity history: the company's audit trail, readable — who changed what and which fields, filtered by entity or text; restricted content never enters the trail | plan 030 | E2E UI change → shown with actor and diff → filter narrows; unit tests for the summaries |
| Payroll preparation: a period per company, range and currency snapshots every approved record in force day by day (amount, basis, from / to, days covered — facts, not computed pay); prepared by one person, approved by another, reopened or marked exported; CSV for the accountant | migration 0023 + plan 031 | E2E prepare → lines → self-approval refused → colleague-prepared approved → CSV content → exported; smoke for mid-period changes, currency filter, transitions, RLS |

## Next (in order)

0. **020 AI assist** — summaries with references, never a score; blocked on
   ANTHROPIC_API_KEY in .env.local.
2. **Turn on Zoho sync** — supply credentials + per-company mapping, then
   run it for real (code is done; see [integrations-zoho.md](integrations-zoho.md)).
3. **Leave-system linking** — shared auth pool with the leave app (one
   password for both), then read-only leave indicators via `leave_links`.
4. **Company profile leftovers (needs credentials)** — notification contacts
   once an email path exists (RESEND_API_KEY); Integrations tab connect /
   configure once provider credentials exist.
5. **Later, per blueprint** — recruitment marketing + channel integrations,
   import preview, rehire, equipment on onboarding / offboarding checklists,
   payroll allowances and one-off items.

## Standing rules

- Schema changes = new numbered migration + `local-verify.sh` green + apply to
  live + regenerate `app/src/types/database.ts`.
- Every slice ships with E2E in `app/e2e/` against the live project.
- Authorization lives in RLS; the app renders what the database allows.
- Open items: fourth company name (Liquiditas?), RESEND_API_KEY for credential
  emails, real COMPANY_EMAIL_DOMAINS values, temp admin password rotation.
