# Plan 016: Offboarding UI — departures as a workflow

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-0011, `10407ee`)
- **Category**: feature (blueprint §9 step 6 — offboarding; core plan §7)

## Why this matters

Migration 0010 shipped the database half of offboarding — `schedule_departure`
(dates + restricted reason + one offboarding plan, idempotent) and
`complete_departure` (the explicit act of becoming Former, allowed with open
tasks) — but nothing in the app calls them. The person page still has a crude
"End employment" that flips `status = 'former'` today, with no dates, no
reason, no plan. This plan makes departures the workflow the core plan
describes: schedule → tasks → mark as former, with an HR queue.

## Current state (all committed on main)

- RPCs: `public.schedule_departure(p_employment_period_id uuid, p_end_date
  date, p_last_working_date date default null, p_reason text default null)`
  → `{ plan_id, already_scheduled }`; `public.complete_departure(
  p_employment_period_id uuid)` → `{ plan_id, open_tasks }`. Both require
  `departure.start` in the period's company (admins pass). Errors are
  readable sentences (see 0010).
- `employment_periods`: status ('pre_start'|'active'|'former'), start_date,
  end_date, last_working_date. A period with `end_date` set and status ≠
  former is "departing".
- `employment_departure_details(employment_period_id, reason, recorded_by,
  recorded_at)` — readable only by `departure.start` / `personal.view`
  holders (RLS), never by plain `people.view` or the person.
- `plans.kind` ∈ onboarding|offboarding; `plan_phases` now includes
  before_last_day / last_day / after_departure (sort 50–70).
- `task_templates` shared row 'Standard offboarding' with 5 template tasks
  (handover, exit conversation, equipment, access removal, final documents).
- Capabilities: `departure.start` is held by Company HR and Holding HR
  presets; `auth` store exposes only `isAdmin` / `personId`. Own grants are
  readable by self (`access_grants` + `grant_capabilities`), as My workspace
  already queries.
- Pages to model on: `OnboardingPage.vue` (queue), `OnboardingPlanPage.vue`
  (phases, task actions, finish), `PersonProfilePage.vue` (employment rows,
  `endEmployment`). E2E to model on: `app/e2e/onboarding.spec.ts` (seeds a
  person + period + plan with the service client).

## Scope

In:
1. `auth.can(companyId, capability)` from the user's own grants (admins: always
   true). Loaded with the person record; no new tables.
2. Person profile employment rows: **Schedule departure** dialog (end date,
   last working date, optional restricted reason) → RPC; "Departing · last
   day …" state with **Mark as former** → RPC. Remove `endEmployment`.
3. `/offboarding` queue page + nav link; **Departing** badge in the directory.
4. Plan detail page kind-aware: `/offboarding/:planId` route to the same
   component; labels and the finish action switch on `plan.kind`
   (offboarding finish = `complete_departure`).
5. Tests: unit (`lib/departure.ts` state + form schema), E2E
   `offboarding.spec.ts`, `people.spec.ts` updated to the new flow.

Out: departures on Home / company overview metrics, rehire, scheduled job or
manager changes (plan 017), company-specific offboarding templates (rows can
be added without code).

## Steps

1. **RED** unit tests for `lib/departure.ts`: `departureState(period)`,
   `departureInput` (end ≥ start, last working ≤ end, reason ≤ 500 chars),
   `friendlyDepartureError`. GREEN.
2. Auth store: `capabilities` map + `can()`; `loadPerson` fetches own grants.
3. **RED** E2E `offboarding.spec.ts`: seed person with an active period at
   Praedium → sign in (admin) → profile → Schedule departure → notice links
   to plan → Offboarding queue row shows "N blockers" → open plan → complete
   the critical tasks → "Finish offboarding" → row shows former on the
   profile and completed in the queue; cleanup deletes plan_tasks, plans,
   departure details, periods, person.
4. Build: `ScheduleDepartureDialog.vue`, PersonProfilePage changes,
   `OffboardingPage.vue`, router + nav, plan page kind switch,
   DirectoryPage badge. Typecheck clean. GREEN.
5. Update `people.spec.ts` (schedule + mark as former instead of End
   employment). Run: unit, `people`, `onboarding`, `offboarding`,
   `my-workspace`, `home` specs.
6. `/code-review medium`; fix findings; re-verify.
7. Commit `feat: offboarding UI — schedule departure, queue, mark as former`;
   update `plans/README.md` and `docs/development-plan.md`.

## STOP conditions

- An RPC signature or error text differs from 0010 as quoted above.
- `plan_phases` lacks the three offboarding phases on the live project.
- The admin test user cannot read `access_grants` for themselves.
