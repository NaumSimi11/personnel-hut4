#!/usr/bin/env bash
# local-verify.sh — run all migrations + smoke tests against a disposable
# Postgres container. Usage: ./supabase/tests/local-verify.sh
# Requires: docker, psql. Never touches a real Supabase project.
set -euo pipefail

PORT="${HR_TEST_PG_PORT:-54329}"
NAME="hr-schema-verify"
URL="postgresql://postgres:localtest@127.0.0.1:${PORT}/postgres"
DIR="$(cd "$(dirname "$0")/.." && pwd)"   # .../supabase

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "Starting disposable Postgres 16 on port ${PORT}…"
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=localtest \
  -p "${PORT}:5432" postgres:16-alpine >/dev/null

for i in $(seq 1 30); do
  if psql "$URL" -c 'select 1' >/dev/null 2>&1; then break; fi
  sleep 1
  [ "$i" = 30 ] && { echo "Postgres did not become ready"; exit 1; }
done

echo "Applying Supabase shim (local test only)…"
psql "$URL" -v ON_ERROR_STOP=1 -q -f "$DIR/tests/shim_supabase.sql"

for f in "$DIR"/migrations/*.sql; do
  echo "Applying $(basename "$f")…"
  psql "$URL" -v ON_ERROR_STOP=1 -q -f "$f"
done

echo "Running smoke tests…"
psql "$URL" -v ON_ERROR_STOP=1 -f "$DIR/tests/smoke.sql"
psql "$URL" -v ON_ERROR_STOP=1 -f "$DIR/tests/delete-job-application.sql"

echo "All migrations applied and smoke tests passed."
