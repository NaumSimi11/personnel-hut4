#!/usr/bin/env bash
# zoho-job-view-import.sh — run import_zoho_job_view (migration 0097) on the
# payload server/scripts/zoho-job-view-extract.ts wrote, as the platform admin.
#
#   scripts/zoho-job-view-import.sh --dry-run [payload.json]   # report only, nothing written
#   scripts/zoho-job-view-import.sh --commit  [payload.json]   # all or nothing
#
# The payload defaults to .zoho-job-view.json at the repo root. The database is
# ZOHO_DB_URL when set (a disposable local Postgres for the rehearsal), else
# SUPABASE_DB_URL from .env.local, which is PRODUCTION: a --commit there also
# needs ZOHO_ALLOW_PRODUCTION=true in the environment (a dry run does not).
# The target is printed by name, never the URL. The direct connection is a
# superuser, so the admin is impersonated through the JWT claims the way
# fn-import.sh does; the function still checks platform_admins. Prints counts
# only, never a name; the function's full JSON (with the unmatched names) goes
# to .zoho-job-view-report.json at the repo root (git-ignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
USAGE="usage: $0 --dry-run|--commit [payload.json]"
TAG='[zoho-job-view-import]'
case "${1:-}" in
  --dry-run) COMMIT=false ;;
  --commit) COMMIT=true ;;
  *) echo "$USAGE" >&2; exit 1 ;;
esac
shift
[ "$#" -le 1 ] || { echo "$USAGE" >&2; exit 1; }
case "${1:-}" in --*) echo "$USAGE" >&2; exit 1 ;; esac
PAYLOAD="${1:-$ROOT/.zoho-job-view.json}"
[ -f "$PAYLOAD" ] || { echo "payload not found: $PAYLOAD (run npm run import:zoho-job-view:extract in server/ first)" >&2; exit 1; }
QUOTE='$zohojobview$'
if grep -qF "$QUOTE" "$PAYLOAD"; then
  echo "the payload contains $QUOTE and cannot be embedded" >&2; exit 1
fi

if [ -n "${ZOHO_DB_URL:-}" ]; then
  URL="$ZOHO_DB_URL"
  echo "$TAG target: ZOHO_DB_URL (local)"
else
  URL="$({ grep '^SUPABASE_DB_URL=' "$ROOT/.env.local" 2>/dev/null || true; } | cut -d= -f2- | tr -d '\r"')"
  [ -n "$URL" ] || { echo "SUPABASE_DB_URL missing in .env.local (or set ZOHO_DB_URL)" >&2; exit 1; }
  echo "$TAG target: SUPABASE_DB_URL from .env.local (PRODUCTION)"
  if [ "$COMMIT" = true ] && [ "${ZOHO_ALLOW_PRODUCTION:-}" != true ]; then
    echo "$TAG refusing to --commit to PRODUCTION without ZOHO_ALLOW_PRODUCTION=true" >&2; exit 1
  fi
fi
export PGCLIENTENCODING=UTF8

# The admin's auth uid: the first platform admin's linked user.
ADMIN_UID="$(psql "$URL" -X -At -v ON_ERROR_STOP=1 -c "select p.user_id from public.platform_admins a join public.people p on p.id = a.person_id where p.user_id is not null order by a.granted_at limit 1")"
[ -n "$ADMIN_UID" ] || { echo "no platform admin with an account" >&2; exit 1; }

REPORT="$ROOT/.zoho-job-view-report.json"
# The payload is too big for a command-line variable: embed it dollar-quoted in a temp SQL file.
SQLFILE="$(mktemp)"
trap 'rm -f "$SQLFILE"' EXIT
{
  echo "begin;"
  echo '\o /dev/null'
  # request.jwt.* is what live Supabase's auth.uid() reads; app.test_uid is
  # what the local shim (supabase/tests/shim_supabase.sql) reads. Both set.
  echo "select set_config('request.jwt.claim.sub', '$ADMIN_UID', true),"
  echo "       set_config('request.jwt.claims', json_build_object('sub', '$ADMIN_UID', 'role', 'authenticated')::text, true),"
  echo "       set_config('app.test_uid', '$ADMIN_UID', true);"
  # Only the function's JSON reaches the report file.
  printf '\\o %s\n' "'$REPORT'"
  printf 'select public.import_zoho_job_view(%s' "$QUOTE"
  cat "$PAYLOAD"
  printf '%s::jsonb, %s)::text;\n' "$QUOTE" "$COMMIT"
  echo '\o'
  echo "commit;"
} > "$SQLFILE"
rm -f "$REPORT"
psql "$URL" -X -q -At -v ON_ERROR_STOP=1 -f "$SQLFILE"

python3 - "$REPORT" "$TAG" <<'PY'
import json, sys
# Counts, refused rows (Zoho ids and reasons) and the number of unmatched
# people: never a candidate's or a person's name.
report_path, tag = sys.argv[1], sys.argv[2]
r = json.load(open(report_path, encoding='utf-8'))
tag += ' [committed]' if r['committed'] else ' [dry run]'
print(tag, f"candidates: {r['candidates']} · applications: {r['applications']} · notes: {r['notes']}")
print(tag, 'already there (skipped):', json.dumps(r['existing']))
print(tag, 'contact rules:', json.dumps(r['contact_rules']))
print(tag, f"notes truncated: {r['notes_truncated']} · notes without text: {r['notes_without_text']}")
print(tag, 'by status:')
for key, n in sorted(r['by_status'].items(), key=lambda kv: (-kv[1], kv[0])):
    print(tag, f'   {key}: {n}')
print(tag, f"people not matched by name: {len(r['unmatched_people'])} (names in the full report)")
print(tag, f"refused rows: {len(r['refused'])}")
for row in r['refused']:
    print(tag, 'REFUSED:', json.dumps(row, ensure_ascii=False))
print(tag, 'full report:', report_path)
PY
