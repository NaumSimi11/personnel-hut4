# Plan 038: Cutover from Field Notebook

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: S (code) + a supervised evening (run) /
  **Risk**: MEDIUM (people's sign-ins) / **Depends on**: 037 committed
- **Category**: data migration + runbook. Field Notebook is on Vercel
  (`E:\ht-hpt`, its own Supabase project); Personnel is not deployed yet,
  so the redirect step waits for a Personnel URL.

## Accounts: `scripts/fn-accounts.sh --dry-run | --commit`

Reads the source project's `auth.users` (38 bcrypt hashes) with its
`public.users` flags and creates the same accounts in Personnel's `auth`
schema — same email, same hash, `must_change_password: false`, an email
identity — linked to the person row by email. Rules:

- only accounts whose owner set a password (`passwordSetAt`) come over
  (28); invited-but-never-signed-in ones (10) are listed for HR to invite
  from Personnel, which sends a fresh temporary password;
- disabled accounts are not carried over;
- a person without a row (037 not run) or already linked is skipped and
  listed; an unlinked existing account with the same email is flagged for a
  manual link;
- the source id is kept unless it collides.

The dry run executes everything inside a transaction and rolls back, so
the listing is exactly what the commit will do. Passwords are never
printed or decoded — the hash moves as is (Supabase Auth verifies bcrypt
regardless of which project made it).

## Runbook (one evening)

1. `scripts/fn-extract.sh` → `scripts/fn-import.sh --dry-run` → read the
   report → `--commit` (plan 037).
2. `scripts/fn-accounts.sh --dry-run` → `--commit`.
3. Sign in as one carried-over person from the list to confirm the
   password works and My leave shows their balance.
4. Field Notebook read-only: set `MAINTENANCE=1` there is not available —
   instead deploy its `vercel.json` with
   `"redirects": [{"source": "/(.*)", "destination": "https://<personnel-url>/$1", "permanent": false}]`
   once Personnel has a URL; until then leave it running but tell the
   admins not to approve there any more.
5. Keep the source project for 30 days, then pause it.

## Verification

- `fn-accounts.sh --dry-run` on the live database (before 037): 37 "no
  person row yet", 1 "already has a Personnel account" (the maintainer) —
  the script reads the state correctly and writes nothing.
- After 037 + 038 commit: one real sign-in; `select count(*) from
  public.people where user_id is not null` = 29.
