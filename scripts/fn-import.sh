#!/usr/bin/env bash
# fn-import.sh — run import_field_notebook (plan 037) against the live
# Personnel database as the platform admin.
#
#   scripts/fn-import.sh --dry-run [payload.json]   # report only, nothing written
#   scripts/fn-import.sh --commit  [payload.json]   # all or nothing
#
# Needs SUPABASE_DB_URL in .env.local (the direct connection is a superuser,
# so the admin is impersonated through app.test_uid the way the smoke tests
# do — the function still checks platform_admins). Prints the report; the
# balance table and the approver grants deserve a careful read before
# --commit. Nothing secret is printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
PAYLOAD="${2:-$ROOT/.fn-payload.json}"
case "$MODE" in
  --dry-run) COMMIT=false ;;
  --commit) COMMIT=true ;;
  *) echo "usage: $0 --dry-run|--commit [payload.json]" >&2; exit 1 ;;
esac
[ -f "$PAYLOAD" ] || { echo "payload not found: $PAYLOAD (run scripts/fn-extract.sh first)" >&2; exit 1; }
URL="$(grep '^SUPABASE_DB_URL=' "$ROOT/.env.local" | cut -d= -f2- | tr -d '\r"')"
[ -n "$URL" ] || { echo "SUPABASE_DB_URL missing in .env.local" >&2; exit 1; }

# The admin's auth uid: the first platform admin's linked user.
ADMIN_UID="$(psql "$URL" -X -At -c "select p.user_id from public.platform_admins a join public.people p on p.id = a.person_id where p.user_id is not null order by a.granted_at limit 1")"
[ -n "$ADMIN_UID" ] || { echo "no platform admin with an account" >&2; exit 1; }

REPORT="${PAYLOAD%.json}.report.json"
# The payload is too big for a command-line variable: embed it dollar-quoted in a temp SQL file.
SQLFILE="$(mktemp)"
trap 'rm -f "$SQLFILE"' EXIT
{
  echo "begin;"
  echo "select set_config('request.jwt.claim.sub', '$ADMIN_UID', true),"
  echo "       set_config('request.jwt.claims', json_build_object('sub', '$ADMIN_UID', 'role', 'authenticated')::text, true);"
  printf 'select public.import_field_notebook($fnpayload$'
  cat "$PAYLOAD"
  printf '$fnpayload$::jsonb, %s)::text;
' "$COMMIT"
  echo "commit;"
} > "$SQLFILE"
psql "$URL" -X -q -At -v ON_ERROR_STOP=1 -o "$REPORT" -f "$SQLFILE"

python - "$REPORT" "$COMMIT" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding='utf-8').read().strip().split('\n')
r = json.loads(lines[-1])
tag = '[fn-import]' + (' [committed]' if r['committed'] else ' [dry run]')
print(tag, 'counts:', json.dumps(r['counts']))
for a in r['assumptions']:
    print(tag, 'assumption:', json.dumps(a))
for row in r['rows']:
    if row.get('problems'):
        print(tag, 'REFUSED:', json.dumps(row, ensure_ascii=False))
linked = [x['name'] for x in r['rows'] if x.get('action') == 'linked to the existing record']
if linked:
    print(tag, 'linked to existing records:', ', '.join(linked))
print(tag, f"holidays skipped (per faith/community): {len(r['skipped_holidays'])}")
print(tag, 'approver grants:')
for g in r['grants']:
    print(tag, f"   {g['email']} → {g['company']}: {', '.join(g['capabilities'])}")
print(tag, 'balances (name · entitlement · source remaining · reconciled by · verified):')
for b in r['balances']:
    print(tag, f"   {b['name']} · {b['entitlement']} · {b['source_remaining']} · {b.get('reconciled_by', '?')} · {b['verified']}")
print(tag, 'full report:', sys.argv[1])
PY
