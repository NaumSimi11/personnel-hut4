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

## Next (in order)

0. **Recruitment programme** (in order): 020 AI assist (summaries with
   references, never a score; needs ANTHROPIC_API_KEY) → 021 reporting.
1. **Employment changes** (plan 022) — scheduled job / manager / location
   changes with effective dates, manager field + circular-reporting guard,
   departments & locations management (tables exist, no UI), directory
   filters (active / upcoming / departing / former).
2. **Turn on Zoho sync** — supply credentials + per-company mapping, then
   run it for real (code is done; see [integrations-zoho.md](integrations-zoho.md)).
3. **Compensation** — `compensation_records` UI (propose / approve, history),
   `salary.*`-gated; company default currency.
4. **Leave-system linking** — shared auth pool with the leave app (one
   password for both), then read-only leave indicators via `leave_links`.
5. **Company profile leftovers** — upcoming starters / departures and open
   tasks on the overview; `settings` overrides (notification contacts,
   workflow owners); Integrations tab connect / configure; invite from the
   company Access tab.
6. **Later, per blueprint** — documents & policies, equipment/IT, payroll
   preparation, audit history tab, reports, recruitment marketing + channel
   integrations, import preview, rehire.

## Standing rules

- Schema changes = new numbered migration + `local-verify.sh` green + apply to
  live + regenerate `app/src/types/database.ts`.
- Every slice ships with E2E in `app/e2e/` against the live project.
- Authorization lives in RLS; the app renders what the database allows.
- Open items: fourth company name (Liquiditas?), RESEND_API_KEY for credential
  emails, real COMPANY_EMAIL_DOMAINS values, temp admin password rotation.
