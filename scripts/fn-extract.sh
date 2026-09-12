#!/usr/bin/env bash
# fn-extract.sh — read Field Notebook (plan 037) and write the import payload
# as JSON. Read-only against the source; prints only counts.
#
#   scripts/fn-extract.sh [out.json]
#
# Needs MIGRATION_DATABASE_URL in .env.hr-hut4.local (session pooler) and
# psql on PATH. The company mapping and the approver companies live here,
# in plain sight, so the dry run report can be read against them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.fn-payload.json}"
URL="$(grep '^MIGRATION_DATABASE_URL=' "$ROOT/.env.hr-hut4.local" | cut -d= -f2- | tr -d '\r"')"
[ -n "$URL" ] || { echo "MIGRATION_DATABASE_URL missing in .env.hr-hut4.local" >&2; exit 1; }

psql "$URL" -X -q -At -v ON_ERROR_STOP=1 -o "$OUT" <<'SQL'
with people as (
  select tp.id as fn_id, tp.name, tp.email, tp.phone, tp.company, tp.country,
         d.name as department, p.title as position, tp."isActive" = 1 as is_active,
         tp."annualAllowance" as allowance, tp."balanceRemaining" as remaining,
         tp."updatedAt" as updated_at,
         (select min(r."startDate") from "leaveRequests" r where r."teamPersonId" = tp.id) as first_request
  from "teamPeople" tp
  left join departments d on d.id = tp."departmentId"
  left join positions p on p.id = tp."positionId"
),
requests as (
  select r.id as fn_id, r."teamPersonId" as person_fn_id, r."leaveType" as type,
         r."startDate" as start, r."endDate" as "end", r."requestedWorkingDays" as working_days,
         r."carryOverDaysUsed" as carry_over_used, r.note, r.status::text as status,
         r."documentsToFollow" = 1 as documents_to_follow,
         su.email as submitted_by_email, du.email as decided_by_email, r."decidedAt" as decided_at,
         cu.email as cancelled_by_email, r."cancelledAt" as cancelled_at, r."cancellationReason" as cancellation_reason,
         r."cancellationRequestedAt" as cancellation_requested_at, r."cancellationRequestReason" as cancellation_request_reason,
         r."cancellationDeclinedAt" as cancellation_declined_at, xu.email as cancellation_declined_by_email,
         r."cancellationDeclineNote" as cancellation_decline_note, r."createdAt" as created_at
  from "leaveRequests" r
  left join users su on su.id = r."submittedByUserId"
  left join users du on du.id = r."decidedByUserId"
  left join users cu on cu.id = r."cancelledByUserId"
  left join users xu on xu.id = r."cancellationDeclinedByUserId"
),
adjustments as (
  select a."teamPersonId" as person_fn_id, a.days, a.kind::text as kind, a.reason, u.email as created_by_email, a."createdAt" as created_at
  from "balanceAdjustments" a left join users u on u.id = a."createdByUserId"
),
holidays as (
  select h.country, h.date, h.name, (h.religion::text = 'none' and h.community::text = 'none') as universal
  from "holidayDates" h
),
approvers as (
  -- Field Notebook admins: HUT4 Capital admins looked after every company; others their own.
  select u.email,
         case when tp.company in ('HUT4 Capital', 'HUT4') then jsonb_build_array('HUT4', 'SYNA', 'LIQU', 'SNOW', 'PRAE')
              when tp.company = 'Synami' then jsonb_build_array('SYNA')
              when tp.company = 'Liquiditas' then jsonb_build_array('LIQU')
              when tp.company = 'Snowball' then jsonb_build_array('SNOW')
              when tp.company = 'Praedium' then jsonb_build_array('PRAE')
              else '[]'::jsonb end as short_codes
  from users u join "teamPeople" tp on tp."linkedUserId" = u.id
  where u.role::text = 'admin' and u."disabledAt" is null
)
select jsonb_build_object(
  'year', 2026,
  'companies', jsonb_build_array(
    jsonb_build_object('fn_name', 'HUT4 Capital', 'short_code', 'HUT4'),
    jsonb_build_object('fn_name', 'HUT4', 'short_code', 'HUT4'),
    jsonb_build_object('fn_name', 'Synami', 'short_code', 'SYNA'),
    jsonb_build_object('fn_name', 'Snowball', 'short_code', 'SNOW'),
    jsonb_build_object('fn_name', 'Praedium', 'short_code', 'PRAE'),
    jsonb_build_object('fn_name', 'Liquiditas', 'short_code', 'TBD1', 'rename_to', 'Liquiditas', 'new_short_code', 'LIQU')),
  'people', (select coalesce(jsonb_agg(to_jsonb(p) order by fn_id), '[]'::jsonb) from people p),
  'requests', (select coalesce(jsonb_agg(to_jsonb(r) order by fn_id), '[]'::jsonb) from requests r),
  'adjustments', (select coalesce(jsonb_agg(to_jsonb(a) order by created_at), '[]'::jsonb) from adjustments a),
  'holidays', (select coalesce(jsonb_agg(to_jsonb(h) order by country, date), '[]'::jsonb) from holidays h),
  'approvers', (select coalesce(jsonb_agg(to_jsonb(x) order by email), '[]'::jsonb) from approvers x)
)::text;
SQL

python - "$OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
print('[fn-extract] wrote', sys.argv[1])
for k in ('people', 'requests', 'adjustments', 'holidays', 'approvers'):
    print(f'[fn-extract] {k}: {len(d[k])}')
PY
