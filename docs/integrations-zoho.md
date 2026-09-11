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
