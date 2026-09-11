#!/usr/bin/env bash
# apply-migrations.sh — apply supabase/migrations/*.sql to the LIVE Supabase
# database, in order, using SUPABASE_DB_URL from .env.local.
# Usage: ./supabase/apply-migrations.sh --yes
# (tests/shim_supabase.sql is for local containers only and is never applied.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/supabase"

[ "${1:-}" = "--yes" ] || {
  echo "This applies migrations to the LIVE database. Re-run with --yes to confirm."
  exit 1
}

DB_URL="$(grep '^SUPABASE_DB_URL=' "$ROOT/.env.local" | cut -d= -f2-)"
[ -n "$DB_URL" ] || {
  echo "SUPABASE_DB_URL is empty in .env.local."
  echo "Get it from Supabase Dashboard → Connect → Session pooler URI."
  exit 1
}

psql "$DB_URL" -c 'select 1' >/dev/null || { echo "Cannot connect."; exit 1; }

for f in "$DIR"/migrations/*.sql; do
  echo "Applying $(basename "$f")…"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$f"
done

echo "All migrations applied to the live database."
