# Plan 037: Import from Field Notebook, with a verifier

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: M / **Risk**: MEDIUM (live data, one shot)
  / **Depends on**: 036 (`fc4f933`)
- **Category**: data migration. Source: Field Notebook's Supabase project
  (credentials in `.env.hr-hut4.local`, read only). Everything lands
  through one database function so the whole import is one transaction
  and the dry run is the same code path.

## What the source holds (2026-09-12)

42 people (39 active; 18 at HUT4 Capital, 19 Synami incl. 2 in Serbia,
2 Snowball, 2 Liquiditas incl. 1 in Malta, 0 Praedium), 38 accounts (3
admins), 105 requests (100 annual approved, 3 rejected, 2 justified days),
18 adjustments (6 real: 5 manual + 1 allowance change; the rest mirror
approvals), 78 holidays (62 universal, 16 per faith / community), 0
attachments, 0 balance-year rows — balances live on the person as
`annualAllowance` / `balanceRemaining`. No hire dates.

## Migration 0028: `import_field_notebook(p_payload jsonb, p_commit)`

Platform admins only. Payload built by `scripts/fn-extract.sh` (psql →
JSON, nothing printed) with the mapping decided here:

- **Companies**: HUT4 Capital / HUT4 → Hut4 (holding); Synami → SYNA;
  Snowball → SNOW; Praedium → PRAE; Liquiditas → TBD1, renamed
  "Liquiditas" / `LIQU`. Each company's `country_code` is set from the
  majority country of its active people when null (Liquiditas → MT,
  Praedium → MK assumed). A person in another country gets a location
  (company + country) so their calendar is right.
- **People**: matched by work email (lower-cased) — an existing person is
  linked, never merged or renamed; the rest are created with phone and
  `custom.field_notebook = {id, start_date_assumed: true}`. One employment
  per person: job title = position, department shared by name (created
  when missing), `full_time`, start date **2026-01-01** (assumed — the
  source has none; earlier requests move it back), inactive → former with
  the last update as end date.
- **Requests**: `legacy_id` = source id (re-runs skip what is there),
  type by name, snapshot of working days and carry-over used, status,
  notes, actors resolved by email, timestamps kept.
- **Balances**: `leave_balances(year 2026)` entitlement = allowance,
  carry-over 0; real adjustments as `leave_adjustments(kind import)` with
  their reasons; then one reconciliation adjustment where the computed
  remaining still differs from `balanceRemaining`. **Verifier**: after
  writing, `leave_balance(...)->remaining` must equal the source for every
  person, else the transaction is refused.
- **Holidays**: universal rows upserted per country (MK/RS/MT); per-faith
  rows listed as skipped (one calendar per country).
- **Approvers**: the 3 Field Notebook admins get an access grant with
  leave.view / leave.approve / leave.adjust / holidays.manage in the
  companies the payload names (HUT4 Capital admins: every company; the
  Synami admin: Synami). The dry run prints the list before anything is
  written.

Report: counts, refusals per row, assumptions, skipped holidays, approver
grants, the balance verification table. `p_commit = false` returns it
without writing; `true` writes all or nothing.

## Steps

1. Migration + smoke test with a fixture payload (existing person linked,
   new person created, request with legacy id twice = once, balance
   reconciled and verified, mismatch refused, per-faith holiday skipped,
   grants created, non-admin refused).
2. `scripts/fn-extract.sh` + `scripts/fn-import.sh --dry-run|--commit`.
3. Dry run against live → review the report with the maintainer → commit.
4. Types regenerated; docs.
