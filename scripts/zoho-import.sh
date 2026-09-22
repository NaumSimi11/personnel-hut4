#!/usr/bin/env bash
# zoho-import.sh — run import_zoho_recruit (plan 052) or, with --history,
# import_zoho_history (plan 055) against the Personnel database as the
# platform admin.
#
#   scripts/zoho-import.sh --dry-run [payload.json]             # report only, nothing written
#   scripts/zoho-import.sh --commit  [payload.json]             # all or nothing
#   scripts/zoho-import.sh --dry-run --history [payload.json]   # the notes, interviews and reviews
#   scripts/zoho-import.sh --commit  --history [payload.json]
#
# --history defaults the payload to .zoho-history.json and prints the
# history report: the counts and the skipped rows grouped by reason — counts
# only, never a name.
#
# The database is ZOHO_DB_URL when set (a disposable local Postgres for the
# rehearsal), else SUPABASE_DB_URL from .env.local. The direct connection is
# a superuser, so the admin is impersonated through the JWT claims the way
# fn-import.sh does — the function still checks platform_admins. Prints the
# report summary: counts, refused rows, unresolved users, possible duplicates
# and the hires table. Nothing from .env.local is printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
USAGE="usage: $0 --dry-run|--commit [--history] [payload.json]"
MODE="${1:-}"
case "$MODE" in
  --dry-run) COMMIT=false ;;
  --commit) COMMIT=true ;;
  *) echo "$USAGE" >&2; exit 1 ;;
esac
shift
HISTORY=false
PAYLOAD=""
for ARG in "$@"; do
  case "$ARG" in
    --history) HISTORY=true ;;
    --*) echo "$USAGE" >&2; exit 1 ;;
    *) PAYLOAD="$ARG" ;;
  esac
done
if [ "$HISTORY" = true ]; then
  FUNCTION="public.import_zoho_history"
  EXTRACT="import:zoho-history:extract"
  PAYLOAD="${PAYLOAD:-$ROOT/.zoho-history.json}"
else
  FUNCTION="public.import_zoho_recruit"
  EXTRACT="import:zoho-recruit:extract"
  PAYLOAD="${PAYLOAD:-$ROOT/.zoho-payload.json}"
fi
[ -f "$PAYLOAD" ] || { echo "payload not found: $PAYLOAD (run npm run $EXTRACT in server/ first)" >&2; exit 1; }
if [ -n "${ZOHO_DB_URL:-}" ]; then
  URL="$ZOHO_DB_URL"
else
  URL="$(grep '^SUPABASE_DB_URL=' "$ROOT/.env.local" | cut -d= -f2- | tr -d '\r"')"
  [ -n "$URL" ] || { echo "SUPABASE_DB_URL missing in .env.local (or set ZOHO_DB_URL)" >&2; exit 1; }
fi
export PGCLIENTENCODING=UTF8

# The admin's auth uid: the first platform admin's linked user.
ADMIN_UID="$(psql "$URL" -X -At -c "select p.user_id from public.platform_admins a join public.people p on p.id = a.person_id where p.user_id is not null order by a.granted_at limit 1")"
[ -n "$ADMIN_UID" ] || { echo "no platform admin with an account" >&2; exit 1; }

REPORT="${PAYLOAD%.json}.report.json"
# The payload is too big for a command-line variable: embed it dollar-quoted in a temp SQL file.
SQLFILE="$(mktemp)"
trap 'rm -f "$SQLFILE"' EXIT
{
  echo "begin;"
  # request.jwt.* is what live Supabase's auth.uid() reads; app.test_uid is
  # what the local shim (supabase/tests/shim_supabase.sql) reads. Both set.
  echo "select set_config('request.jwt.claim.sub', '$ADMIN_UID', true),"
  echo "       set_config('request.jwt.claims', json_build_object('sub', '$ADMIN_UID', 'role', 'authenticated')::text, true),"
  echo "       set_config('app.test_uid', '$ADMIN_UID', true);"
  printf 'select %s($zohopayload$' "$FUNCTION"
  cat "$PAYLOAD"
  printf '$zohopayload$::jsonb, %s)::text;
' "$COMMIT"
  echo "commit;"
} > "$SQLFILE"
psql "$URL" -X -q -At -v ON_ERROR_STOP=1 -o "$REPORT" -f "$SQLFILE"

if [ "$HISTORY" = true ]; then
python - "$REPORT" <<'PY'
import json, sys
from collections import Counter
# The history report (plan 055 §1): counts, the skipped rows by reason and
# the problems. Reasons and counts only — never a candidate or a user name.
lines = open(sys.argv[1], encoding='utf-8').read().strip().split('\n')
r = json.loads(lines[-1])
tag = '[zoho-import]' + (' [committed]' if r['committed'] else ' [dry run]')
print(tag, 'counts:', json.dumps(r['counts']))
skipped = r.get('skipped') or []
print(tag, f'skipped rows: {len(skipped)}')
for (kind, reason), n in sorted(Counter((s.get('kind'), s.get('reason')) for s in skipped).items()):
    print(tag, f'   {kind} · {reason}: {n}')
problems = r.get('problems') or []
print(tag, f'problems: {len(problems)}')
for p in problems:
    print(tag, 'PROBLEM:', json.dumps(p, ensure_ascii=False))
print(tag, 'full report:', sys.argv[1])
PY
else
python - "$REPORT" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding='utf-8').read().strip().split('\n')
r = json.loads(lines[-1])
tag = '[zoho-import]' + (' [committed]' if r['committed'] else ' [dry run]')
print(tag, 'counts:', json.dumps(r['counts']))
for a in r['assumptions']:
    if a.get('kind') in ('timezone', 'department'):
        print(tag, 'assumption:', json.dumps(a, ensure_ascii=False))
assumed = [a for a in r['assumptions'] if a.get('kind') == 'close_date_assumed']
synth = [a for a in r['assumptions'] if a.get('kind') == 'synthesised_reason']
print(tag, f'assumed close dates: {len(assumed)} · synthesised do-not-contact reasons: {len(synth)}')
refused = [row for row in r['rows'] if row.get('problems')]
print(tag, f'refused rows: {len(refused)}')
for row in refused:
    print(tag, 'REFUSED:', json.dumps(row, ensure_ascii=False))
print(tag, f"users resolved: {len(r['users']['resolved'])} · unresolved: {len(r['users']['unresolved'])}")
for u in r['users']['unresolved']:
    print(tag, f"   unresolved user: {u.get('name') or '?'} <{u.get('email') or '?'}>")
print(tag, f"possible duplicates: {len(r['possible_duplicates'])}")
for d in r['possible_duplicates']:
    print(tag, f"   {d['full_name']} ~ {d['existing_name']} ({d['match']}, existing {d['existing_id']})")
print(tag, f"hires ({len(r['hires'])}): candidate · job · company · hired date · proposal · match")
for h in r['hires']:
    p = h.get('proposal')
    proposal = f"{p['full_name']} ({p['person_id']})" if p else '—'
    match = p['match'] if p else '—'
    print(tag, f"   {h['candidate']} · {h['job']} · {h['company']} · {h.get('hired_date') or '?'} · {proposal} · {match}")
print(tag, 'full report:', sys.argv[1])
PY
fi
