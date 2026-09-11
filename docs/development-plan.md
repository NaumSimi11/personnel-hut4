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

## Next (in order)

1. **Employee records, remaining depth** — scheduled changes with effective
   dates, manager field + circular-reporting guard, private personal details
   (personal.view-gated), departments/locations management, import preview.
2. **Home / needs-action queue** — one place showing hiring requests awaiting
   a decision, applications at offer, and onboarding readiness gaps (the
   prototype's overview, from live data).
3. **Self-service** — my profile, my tasks, my access (the prototype's
   view-as overview, now for the real signed-in person).
5. **Company profiles & projects** — company pages; read-only Zoho Projects
   sync into `external_projects` via the auth service's sibling job.
6. **Leave-system linking** — shared auth pool with the leave app (one
   password for both), then read-only leave indicators via `leave_links`.
7. **Later, per blueprint** — documents & policies, equipment/IT, offboarding,
   payroll preparation, reports, recruitment marketing + channel integrations.

## Standing rules

- Schema changes = new numbered migration + `local-verify.sh` green + apply to
  live + regenerate `app/src/types/database.ts`.
- Every slice ships with E2E in `app/e2e/` against the live project.
- Authorization lives in RLS; the app renders what the database allows.
- Open items: fourth company name (Liquiditas?), RESEND_API_KEY for credential
  emails, real COMPANY_EMAIL_DOMAINS values, temp admin password rotation.
