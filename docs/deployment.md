# Deployment

Personnel is **one origin**: the Fastify service in `server/` (invites,
password changes, careers intake) and the built Vue app together — no CORS,
no proxy rewrites. The database, storage and auth are the Supabase project;
nothing else is needed. The chosen host is Vercel; a Dockerfile exists for
any other platform.

## Vercel (chosen host)

The deployment is declared, not detected: `server/scripts/build-vercel.mjs`
writes a Vercel Build Output API (v3) tree into `server/.vercel/output/` —
the Vue build in `static/` for the CDN, one self-contained function in
`functions/api.func/` for `/api/*`, and `config.json` routing filesystem
first, then `/api/*` to the function, then everything else to `index.html`
for the SPA router. This is the same shape the Hut4 leave system deploys.

Declaring it matters here: the service imports `../../shared`, outside the
project's Root Directory, and esbuild inlines that at build time so the
function depends on nothing beyond its own bundle. The bundle is ESM
(`env.ts` reads `import.meta.url`) with a `createRequire` banner, because
Fastify and its plugins are CommonJS and require Node built-ins at load
time.

Two earlier attempts relied on Vercel's zero-config detection and both
failed: exporting the app from `server/server.ts` named in `functions` is
rejected at build time ("the pattern does not match any Serverless
Functions inside the `api` directory"), and an `api/` entry point builds but
cannot resolve imports from outside the Root Directory.

Project settings (once, in the dashboard):

1. **Import the repository**, set **Root Directory** to `server` and keep
   "Include files outside the root directory" on (the build needs `../app`
   and `../shared`). Framework preset: *Other* — `vercel.json` carries the
   install and build commands.
2. **Environment variables** (Production + Preview):
   `SUPABASE_URL`, `SUPABASE_SECRET_KEY`, `SUPABASE_PUBLISHABLE_KEY`,
   `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` (the two `VITE_`
   ones are read at build time), `COMPANY_EMAIL_DOMAINS`, `APP_BASE_URL`
   (the production URL), `TRUST_PROXY=true`, and when ready
   `RESEND_API_KEY` + `EMAIL_FROM`.
3. Deploy; add the custom domain; set `APP_BASE_URL` to it and redeploy.

Serverless notes: the careers rate limits are in memory, so on Vercel they
are per instance and best-effort — the database rules (one open
application per person and role, honeypot, answer checks) still hold. The
Zoho sync CLI is run from a laptop, not from Vercel.

## Docker (any other host)

### Build

```sh
docker build \
  --build-arg VITE_SUPABASE_URL=https://<project>.supabase.co \
  --build-arg VITE_SUPABASE_PUBLISHABLE_KEY=<publishable key> \
  -t personnel .
```

The two build args are the browser-safe values Vite bakes into the bundle
(the publishable key is meant for browsers; Row Level Security is the gate).
Everything else is a **runtime** variable — never a build arg.

### Run

```sh
docker run -p 8080:8080 \
  -e SUPABASE_URL=https://<project>.supabase.co \
  -e SUPABASE_SECRET_KEY=<secret key> \
  -e SUPABASE_PUBLISHABLE_KEY=<publishable key> \
  -e COMPANY_EMAIL_DOMAINS=hut4.com,synami.com \
  -e APP_BASE_URL=https://people.hut4.com \
  -e RESEND_API_KEY=<optional> -e EMAIL_FROM="Personnel <people@hut4.com>" \
  personnel
```

The image sets `HOST=0.0.0.0`, `PORT=8080`, `SERVE_APP_DIR=/srv/app` and
`TRUST_PROXY=true` (every platform below puts a proxy in front, and the
careers rate limit keys on the forwarded client IP). Health: `GET /` returns
the app; `GET /api/careers/NOPE` returns a JSON 404 once the service can
reach Supabase.

Verified locally: `docker build` + `docker run` → `/` 200 HTML, deep link
`/leave?tab=requests` served by the SPA fallback, assets 200, `/api/*` JSON.

## Database

Migrations are applied with `supabase/apply-migrations.sh --yes` (psql +
`SUPABASE_DB_URL`), never from the container. Nightly jobs
(`apply-due-employment-changes`, `roll-leave-year`) are pg_cron jobs inside
the database, so they run with or without the container.

## Checklist before go-live

1. `.env.local` values mirrored into the platform (see `.env.example`).
2. `COMPANY_EMAIL_DOMAINS` set to the real domains — an empty list admits
   nobody to the invite door.
3. `RESEND_API_KEY` + `EMAIL_FROM` so invitations are emailed (without them
   the temporary password is shown once to the admin only).
4. Rotate the first admin's temporary password.
5. Run the Field Notebook import and account carry-over
   (`plans/037-field-notebook-import.md`, `plans/038-cutover.md`), then
   point the old app's `vercel.json` redirect at the new URL.
