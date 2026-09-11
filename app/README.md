# Personnel — Vue 3 app

The production app for the Hut4 holding HR system. Vue 3 (Composition API) +
TypeScript + Pinia + Vue Router + supabase-js, built with Vite. Data and
authorization live in Supabase; every query runs through Row Level Security,
so the app never enforces access itself — it only renders what the database
allows the signed-in person to see.

## Setup

Environment comes from the repo-root `.env.local` (gitignored — copy
`.env.example` and fill it in). The Vite dev server reads it via `envDir`;
only `VITE_`-prefixed variables reach the browser bundle.

```sh
npm install
npm run dev        # http://localhost:5173
```

Invite, reset-access, and change-password go through the privileged auth
service in `../server` (it holds the secret key; the dev server proxies
`/api` to it). Run it alongside:

```sh
cd ../server && npm install && npm run dev   # http://127.0.0.1:8787
```

Auth flow (ported from the Hut4 leave system): accounts are **invite-only** —
an admin invites a company-domain address, the invitee gets a one-time
temporary password (emailed when Resend is configured, always shown once to
the admin), and the first sign-in forces a password change. Until then both
the router and the database (RLS reads the `must_change_password` claim)
refuse everything else. "Reset access" reissues a temporary password — one
operation for "never got it" and "forgot it".

## Scripts

| Command | What it does |
|---|---|
| `npm run dev` | Vite dev server |
| `npm run build` | Typecheck (vue-tsc, strict) + production build |
| `npm test` | Vitest unit tests (pure logic, e.g. permission dependencies) |
| `npm run test:e2e` | Playwright E2E against a dev server and the live Supabase project (needs `TEST_USER_EMAIL`/`TEST_USER_PASSWORD` in `../.env.local`) |

## Structure

```
src/
  lib/        supabase client, pure permission-set logic (+ unit tests)
  stores/     Pinia: auth session, capability/preset catalog
  router/     routes + auth guard
  pages/      LoginPage, DirectoryPage, AccessEditorPage, CompaniesPage,
              CompanyProfilePage, CompanyFormPage (new/edit, admin), …
  components/ AppShell (sidebar layout)
  types/      database.ts — GENERATED, do not edit:
              npx supabase gen types typescript --db-url "$SUPABASE_DB_URL" (needs Docker)
  styles/     design tokens ported from ../prototype
```

## Conventions

- The permission catalog (capabilities, groups, dependencies, presets) is
  **data read from the database** — new capabilities/presets appear in the UI
  without code changes. Only the group display order is a UI constant.
- Regenerate `src/types/database.ts` after every schema migration.
- All user input is validated with Zod before it leaves a form.
- The design system follows `../prototype/styles.css`; reuse its tokens.
