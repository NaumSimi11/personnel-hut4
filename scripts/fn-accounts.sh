#!/usr/bin/env bash
# fn-accounts.sh — carry Field Notebook sign-ins over to Personnel (plan 038).
#
#   scripts/fn-accounts.sh --dry-run    # runs everything, then rolls back
#   scripts/fn-accounts.sh --commit
#
# Reads auth.users of the Field Notebook project (bcrypt hashes; read only)
# and creates the same accounts in Personnel's auth schema, linked to the
# people rows the 037 import created (matched by email). Only accounts whose
# owner actually set a password come over; invited-but-never-signed-in and
# disabled accounts are listed for HR to invite from Personnel instead.
# Nothing secret is printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
case "$MODE" in
  --dry-run) FINAL="rollback;" ;;
  --commit) FINAL="commit;" ;;
  *) echo "usage: $0 --dry-run|--commit" >&2; exit 1 ;;
esac
FN_URL="$(grep '^MIGRATION_DATABASE_URL=' "$ROOT/.env.hr-hut4.local" | cut -d= -f2- | tr -d '\r"')"
URL="$(grep '^SUPABASE_DB_URL=' "$ROOT/.env.local" | cut -d= -f2- | tr -d '\r"')"
[ -n "$FN_URL" ] && [ -n "$URL" ] || { echo "MIGRATION_DATABASE_URL / SUPABASE_DB_URL missing" >&2; exit 1; }

PAYLOAD="$(mktemp)"; SQLFILE="$(mktemp)"
trap 'rm -f "$PAYLOAD" "$SQLFILE"' EXIT

psql "$FN_URL" -X -q -At -v ON_ERROR_STOP=1 -o "$PAYLOAD" <<'SQL'
select jsonb_agg(jsonb_build_object(
  'id', a.id, 'email', lower(a.email), 'hash', a.encrypted_password,
  'confirmed_at', a.email_confirmed_at, 'created_at', a.created_at, 'last_sign_in_at', a.last_sign_in_at,
  'has_password', u."passwordSetAt" is not null, 'disabled', u."disabledAt" is not null, 'role', u.role::text
) order by a.email)::text
from auth.users a join public.users u on lower(u.email) = lower(a.email)
where a.encrypted_password like '$2%';
SQL

{
  echo "begin;"
  printf 'create temp table fn_accounts as select value as doc from jsonb_array_elements($fnacc$'
  cat "$PAYLOAD"
  printf '$fnacc$::jsonb) as row;\n'
  cat <<'SQL'
create temp table fn_report (email text, outcome text);
do $$
declare r jsonb; v_person uuid; v_existing uuid; v_id uuid;
begin
  for r in select doc from fn_accounts loop
    select id, user_id into v_person, v_existing from public.people where lower(work_email) = r->>'email' and archived_at is null;
    if v_person is null then
      insert into fn_report values (r->>'email', 'no person row yet — run the 037 import first'); continue;
    elsif v_existing is not null then
      insert into fn_report values (r->>'email', 'already has a Personnel account'); continue;
    elsif exists (select 1 from auth.users where lower(email) = r->>'email') then
      insert into fn_report values (r->>'email', 'an account with this email exists but is not linked — link it by hand'); continue;
    elsif (r->>'disabled')::boolean then
      insert into fn_report values (r->>'email', 'disabled in Field Notebook — not carried over'); continue;
    elsif not (r->>'has_password')::boolean then
      insert into fn_report values (r->>'email', 'never set a password — invite from Personnel'); continue;
    end if;
    v_id := case when exists (select 1 from auth.users where id = (r->>'id')::uuid) then gen_random_uuid() else (r->>'id')::uuid end;
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at, last_sign_in_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', r->>'email', r->>'hash',
      coalesce((r->>'confirmed_at')::timestamptz, now()),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'), 'must_change_password', false),
      '{}'::jsonb, coalesce((r->>'created_at')::timestamptz, now()), now(), (r->>'last_sign_in_at')::timestamptz);
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
    values (gen_random_uuid(), v_id, v_id::text, 'email',
      jsonb_build_object('sub', v_id::text, 'email', r->>'email', 'email_verified', true, 'phone_verified', false),
      now(), now(), (r->>'last_sign_in_at')::timestamptz);
    update public.people set user_id = v_id where id = v_person;
    insert into fn_report values (r->>'email', 'account carried over with its password');
  end loop;
end $$;
select outcome, count(*) from fn_report group by outcome order by 2 desc;
select outcome, string_agg(split_part(email, '@', 1), ', ' order by email) from fn_report
  where outcome not like 'account carried over%' group by outcome;
SQL
  echo "$FINAL"
} > "$SQLFILE"

echo "[fn-accounts] ${MODE#--}"
psql "$URL" -X -q -At -F ' | ' -v ON_ERROR_STOP=1 -f "$SQLFILE"
