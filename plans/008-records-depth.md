# Plan 008: Employee records depth — invite↔record unification + private details

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. Touch
> only the files listed as in scope. If any STOP condition occurs, stop and
> report — do not improvise; documented minimal adaptations with clear NOTES
> are acceptable. Commit your work in the worktree on the branch named below.
> Do NOT update `plans/README.md` — the reviewer maintains the index.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW / **Depends on**: current `main`
- **Category**: feature (development-plan item 1)

## Why this matters

Two gaps in the employee-records foundation:

1. **Inviting duplicates people.** `POST /api/auth/invite` refuses when a
   `people` row with that `work_email` exists — so a person added as a record
   (via "Add person") can never be given an account; and before that guard,
   inviting would have created a second person. The right rule (ported from
   the Hut4 leave system's account-linking invariant: identity migration is
   ALWAYS "attach to the existing row", never "insert a duplicate"): invite
   should **attach** an account to an existing record-only person matched by
   work email, **create** person+account when nobody matches, and **refuse**
   when the matched person already has an account (that case is what
   "Reset access" is for).
2. **Private personal details have a table and RLS but no UI.**
   `person_private_details` (birth date, address, emergency contacts, notes)
   is gated by the `personal.view` capability / self-access; the profile page
   should let permitted users view and edit it.

## Current state (all uncommitted work is on `main` — your worktree has it)

- **Auth service**: `server/src/routes.ts` — the invite handler currently:
  ```ts
  const { data: existing } = await db.from('people').select('id').eq('work_email', input.email).maybeSingle()
  if (existing) return fail(reply, 400, 'An account with this email already exists.')
  if (await findAccountByEmail(input.email)) return fail(reply, 400, 'An account with this email already exists.')
  const tempPassword = generateTempPassword()
  const account = await createInvitedAccount({ ...input, tempPassword })
  const { data: person, error: personErr } = await db.from('people')
    .insert({ user_id: account.id, full_name: input.name, work_email: input.email })
    .select('id').single()
  ```
  Pure logic lives in `server/src/account.ts` (with tests in
  `server/src/account.test.ts` — model new tests on it). Supabase admin
  wrappers in `server/src/supabaseAdmin.ts` (`createInvitedAccount`,
  `findAccountByEmail`, `serviceDb`).
- **DB**: `people(id, user_id unique nullable, full_name, work_email, …)`;
  `person_private_details(person_id pk → people, birth_date date, address jsonb,
  emergency_contacts jsonb default '[]', national_id_hint text (≤8 chars check),
  notes text, custom jsonb)`. RLS on person_private_details: SELECT/ALL when
  `app.is_self(person_id)` OR the viewer holds `personal.view` in a company
  where the person has an employment period. NO migration changes are needed
  or allowed in this plan.
- **App**: `app/src/pages/PersonProfilePage.vue` — profile with employment
  history + access cards in a `grid-two` layout; `auth` store exposes
  `isAdmin`, `personId`. Conventions: Vue 3 `<script setup lang="ts">`, Zod at
  boundaries, all Supabase calls typed via `@/types/database`, design tokens in
  `app/src/styles/main.css` (`.card`, `.field`, `.button`, `.badge`,
  `.error-note`, `.empty` etc.), errors surfaced with friendly text +
  `console.error` detail. E2E in `app/e2e/*.spec.ts` — model on
  `app/e2e/people.spec.ts` (admin login helper pattern, service-client cleanup
  via `SUPABASE_URL`/`SUPABASE_SECRET_KEY` process env set by
  `app/playwright.config.ts`).
- **Test credentials**: TEST_USER_EMAIL / TEST_USER_PASSWORD in root
  `.env.local` (gitignored — present on this machine; the worktree shares it
  via absolute paths? NO — the worktree has its own root. Copy nothing; the
  playwright config resolves `../.env.local` RELATIVE to app/, which in your
  worktree does not exist. See Step 0.)

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Install app deps | `cd app && npm install && npx playwright install chromium` | exit 0 |
| Install server deps | `cd server && npm install` | exit 0 |
| Server unit tests | `cd server && npm test` | all pass (5 existing + your new ones) |
| Server typecheck | `cd server && npm run typecheck` | exit 0 |
| App build | `cd app && npm run build` | exit 0 |
| Your E2E only | `cd app && npx playwright test e2e/records-depth.spec.ts` | passes |

## Step 0: worktree env

The repo-root `.env.local` is gitignored, so your worktree lacks it. Copy it
from the main checkout (read-only source of truth):
`cp /Users/naum/Downloads/files/.env.local ./.env.local` (at your worktree
root). Verify: `grep -c SUPABASE_URL .env.local` → ≥1. Never commit it (it is
gitignored) and never print its values.

Ports: the main checkout may be running a dev server on 5173 and the auth
service on 8787. Your E2E uses 5199 (vite) and 8787 (auth service) —
`reuseExistingServer: true` would silently reuse the OLD auth service and your
server changes would not be exercised. Before running E2E, verify port 8787 is
free: `lsof -ti :8787` → empty. If it is NOT empty, STOP and report (the
reviewer will free it) — do not kill processes you did not start.

## Scope

**In scope**:
- `server/src/account.ts` (add the pure attachment-decision function)
- `server/src/account.test.ts` (tests for it)
- `server/src/routes.ts` (invite handler only)
- `app/src/pages/PersonProfilePage.vue` (private-details card)
- `app/src/components/PrivateDetailsCard.vue` (create)
- `app/e2e/records-depth.spec.ts` (create)

**Out of scope** (do NOT touch): `supabase/` (no migrations), `shared/`,
`app/src/stores/`, `app/src/router/`, `app/src/lib/`, other pages/components,
existing e2e specs, `prototype/`, `plans/`, `.env*`, `docs/`.

## Git workflow

- Branch from main: `git checkout -b feature/008-records-depth`
- Conventional commits, e.g. `feat: attach invited accounts to existing people records`
- Do NOT push, do NOT merge.

## Steps

### Step 1: Pure attachment decision + tests (server)

In `server/src/account.ts` add:

```ts
export type InvitePlan =
  | { action: 'create' }
  | { action: 'attach'; personId: string }
  | { action: 'refuse'; reason: 'has_account' }

/**
 * Invite-vs-record rule (ported from the leave system's account-linking
 * invariant): attach to an existing record-only person, never duplicate;
 * a person who already has an account gets "Reset access", not a new invite.
 */
export function planInvite(existing: { id: string; user_id: string | null } | null): InvitePlan {
  if (!existing) return { action: 'create' }
  if (existing.user_id) return { action: 'refuse', reason: 'has_account' }
  return { action: 'attach', personId: existing.id }
}
```

Add tests in `server/src/account.test.ts` covering all three branches.

**Verify**: `cd server && npm test` → all pass; `npm run typecheck` → exit 0.

### Step 2: Rewire the invite handler (server)

In `server/src/routes.ts`, replace the existing-person guard + insert with the
plan: select `id, user_id, full_name` by `work_email`; `planInvite(existing)`;
- `refuse` → 400 `'This person already has an account. Use "Reset access" to issue a new password.'`
- keep the `findAccountByEmail` guard ONLY for the `create` path (an auth
  account with no people row still means a broken half-state — refuse as today);
  for `attach`, a dangling auth account with this email is the same
  half-state: refuse with the same message.
- `attach` → `createInvitedAccount` (use the EXISTING person's `full_name` as
  the account name, not the submitted one), then
  `db.from('people').update({ user_id: account.id }).eq('id', plan.personId)`
  (error-checked); respond with that personId.
- `create` → current behavior unchanged.
The email + one-time-credential response stays identical for both paths.

**Verify**: `cd server && npm run typecheck` → exit 0.

### Step 3: Private details card (app)

Create `app/src/components/PrivateDetailsCard.vue`, props `{ personId: string }`:
- Loads `person_private_details` by `person_id` (`maybeSingle`). RLS decides
  visibility; a null row for a permitted viewer just means "nothing recorded".
- Client-side, render the card only when `auth.isAdmin || auth.personId === props.personId`
  (matching how RLS will behave for the current fixtures; RLS remains the
  actual gate).
- Fields (keep exactly these): birth date (`date` input ↔ `birth_date`),
  address line (text ↔ `address` jsonb as `{ line: string }`), one emergency
  contact (name + phone ↔ `emergency_contacts` jsonb as
  `[{ name, phone }]`), notes (textarea ↔ `notes`).
- Edit mode with Save → `upsert({ person_id, ...fields })` (error-checked,
  friendly `.error-note` on failure, success note). A "Sensitive" badge in the
  card head: `<span class="badge amber">Sensitive</span>`.
- Match the profile page's card markup and the codebase style (esc not needed —
  Vue templates escape by default).

Mount it in `PersonProfilePage.vue`'s right-hand column below the Access card.

**Verify**: `cd app && npm run build` → exit 0.

### Step 4: E2E

Create `app/e2e/records-depth.spec.ts` (model on `people.spec.ts`; same
cleanup style). Constants: person name `E2E Attach Target`, email
`e2e-attach@synami.com` (on the allowlist). Clean both `people` (and their
`employment_periods`, `person_private_details`) and any auth user with that
email in beforeAll/afterAll. One test, sequential flow:

1. Admin signs in. "Add person" → name `E2E Attach Target`, work email
   `e2e-attach@synami.com`, company Praedium, title `Attach Probe`. Row
   appears.
2. Open the profile via the name link → expect "no account — record only".
3. Back on the directory: "Invite person" → name `Ignored Name`, email
   `e2e-attach@synami.com` → credential dialog appears (temp password
   captured), Done. **Assert the directory still shows exactly ONE row**
   containing `E2E Attach Target` (`page.locator('tr', { hasText: 'E2E Attach Target' })`
   → count 1) and none containing `Ignored Name`.
4. Open the profile again → expect "has sign-in account".
5. Private details: on the profile, fill birth date `1990-05-04`, address
   `Test Street 1`, emergency contact name+phone, Save → success note. Reload
   the page → values persisted.
6. Inviting the same email AGAIN must fail with the reset-access message
   (assert the dialog shows the error).

**Verify**: `cd app && npx playwright test e2e/records-depth.spec.ts` → 1 passed.

### Step 5: Full local gates

**Verify**: `cd server && npm test` (all), `cd app && npm test` (unit) and
`npm run build` — all green. Do NOT run the full Playwright suite (the
reviewer runs it serially to avoid live-DB collisions); run only your spec.

## Done criteria

- [ ] `server npm test` green including ≥3 new planInvite tests
- [ ] `server npm run typecheck` exit 0
- [ ] `app npm run build` exit 0
- [ ] `app npx playwright test e2e/records-depth.spec.ts` → 1 passed
- [ ] `git diff --stat main` touches ONLY in-scope files
- [ ] Committed on `feature/008-records-depth`

## STOP conditions

- The invite handler in `routes.ts` doesn't match the excerpt (drift).
- Port 8787 is occupied when you need to run E2E (report; don't kill).
- Your E2E fails twice for reasons that look like live-data state rather than
  your code (report what the DB contained).
- Anything requires touching an out-of-scope file.

## Maintenance notes

- The refuse-on-dangling-auth-account case (auth user exists, no people row)
  is rare half-state; "Reset access" on a person row heals the normal cases.
  A cleanup admin tool is future work.
- `national_id_hint` is deliberately NOT in the UI fields — add only with an
  explicit product decision.

## Report format (reply with exactly this)

```
STATUS: COMPLETE | STOPPED
STEPS: per step — done/skipped + verification result
STOPPED BECAUSE: (only if STOPPED)
FILES CHANGED: list
NOTES: deviations/surprises + worktree path + branch + final commit SHA
```
