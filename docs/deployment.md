# Deployment

Personnel runs as **one container**: the Fastify service in `server/`
(invites, password changes, careers intake, Zoho sync) also serves the built
Vue app from `app/dist`, so the product is a single origin — no CORS, no
proxy rewrites. The database, storage and auth are the Supabase project;
nothing else is needed.

## Build

```sh
docker build \
  --build-arg VITE_SUPABASE_URL=https://<project>.supabase.co \
  --build-arg VITE_SUPABASE_PUBLISHABLE_KEY=<publishable key> \
  -t personnel .
```

The two build args are the browser-safe values Vite bakes into the bundle
(the publishable key is meant for browsers; Row Level Security is the gate).
Everything else is a **runtime** variable — never a build arg.

## Run

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

## Where to host

Any container platform works; all of them read the `Dockerfile` from the
repo root and inject the runtime variables from their dashboard:

| Platform | Notes |
|---|---|
| **Fly.io** | `fly launch --no-deploy` (accept the Dockerfile), set secrets with `fly secrets set …`, build args via `[build.args]` in `fly.toml`, `fly deploy`. Cheapest for one small always-on machine. |
| **Railway / Render** | "Deploy from repo", Dockerfile detected; build args and variables in the service settings. |
| **Vercel** | Not for this shape: the service holds long-lived state (rate limits) and a Fastify listener. Field Notebook's `vercel.json` redirect points *at* the URL you get from one of the above. |

Custom domain and TLS come from the platform. `APP_BASE_URL` must be the
public URL — it is what credential emails link to.

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
