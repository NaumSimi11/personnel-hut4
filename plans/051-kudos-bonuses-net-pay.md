# Plan 051: Kudos values, bonuses and net pay (the prototype's model, for now)

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW / **Depends on**: 050
- **Category**: product. Sixth and last slice of plan 045: the prototype's
  Admin tab (kudos values, kudos management) and the payroll extras the
  maintainer accepted for now — bonuses swept into the next period, and a
  net estimate from a tax percentage and a flat deduction per company.

## 1. What changes

### 1.1 Database (migration 0044)

- **`kudos_values`** holding-wide: name, description, active, sort order;
  seeded once with Teamwork · Ownership · Customer focus · Innovation ·
  Integrity. Read by everyone signed in; `save_kudos_value(id, p)` (admin)
  adds, edits or retires one. A retired value keeps its name on the kudos
  already tagged with it (never deleted).
- **`kudos.value_id`** (optional, checked active on insert) and
  **`kudos.posted_by`** (who recorded a kudos on someone's behalf).
  `app.can_manage_kudos(to)` — admin, or `people.view` where the receiver is
  employed (never just being the receiver). Delete extends to managers.
- **`record_kudos(p)`** — from, to, message, value, date — HR posts on a
  colleague's behalf with a date; **`update_kudos(id, p)`** edits any of
  those; **`kudos_overview(p_month)`** — the rows a manager may manage,
  the months with counts, the counts per value (month filter applied).
- `dashboard_snapshot` carries `value_id` / `value_name` per kudos row.
- **`payroll_items`** — a bonus: person, company, amount > 0, currency,
  reason, `item_date`, `period_id` once swept, `created_by`.
  `add_payroll_item(p)` / `remove_payroll_item(id)` (pending only) need
  `payroll.individual` in the company; the person reads their own.
- **Payroll settings** per company in `companies.settings -> 'payroll'`:
  `tax_rate_percent` (0–100) and `deductions_flat` (≥ 0);
  `payroll_settings(company)` (holding fallback, like first-day details),
  `set_payroll_settings(company, p)` (`payroll.individual` or admin).
- **Lines** gain `bonus`, `gross`, `tax`, `deductions`, `net`; the period
  snapshots the `tax_rate_percent` / `deductions_flat` used and a
  `reopened_at`. `prepare_payroll_period`: after the lines, the pending
  items of the company in the period's currency dated on or before the
  period end attach to the period **when the person has a line**; the
  bonus and the flat deduction go on the person's first line, the tax on
  every line's gross (`gross = amount + bonus`, `tax = gross × rate`,
  `net = gross − tax − deductions`, rounded to cents); the result says how
  many bonuses were included and how many stay pending because the person
  has no line. Preparing again releases the period's items first.
  `reopen_payroll_period` releases the items and stamps `reopened_at`;
  `approve_payroll_period` refuses a reopened period until it is prepared
  again (the lines would carry bonuses that are pending again).
- The base of the estimate is the **recorded amount as it stands** (the
  line already says its pay basis and days); pro-rating an annual or
  daily record is not attempted — the accountant's, like the statutory
  contributions.

### 1.2 App

- **Kudos page** (`/kudos`, nav for admins and `people.view` holders):
  month filter with counts, counts per value, "Add kudos" on someone's
  behalf (from, to, date, value, message), the table with edit and
  remove; **Kudos values** card (admins): add, edit, retire.
- **Celebrate**: the value picker on "Give kudos"; the pill on the wall.
- **Payroll tab**: a *Bonuses* card — add (person, amount, currency,
  reason, date), the pending list with remove, the included ones with
  their period; the periods panel shows base · bonus · gross · tax ·
  deductions · net per line and the period totals (gross, tax,
  deductions, net) marked *estimate — statutory contributions are the
  accountant's*; a reopened period says "prepare again" and hides
  Approve; the CSV carries base, bonus, gross, tax, deductions, net.
- **Settings → Payroll**: tax rate and flat deduction (Settings tab now
  also opens for `payroll.individual` holders).

### 1.3 Tests

- Smoke `0044`: the five values seeded; a kudos with a value from the
  giver; HR records one on a colleague's behalf with a date and edits it;
  an inactive value is refused on insert; the receiver cannot edit or
  delete via management; overview counts; a pending bonus lands in the
  next period once (attached, bonus on the first line, tax and net right,
  totals); a bonus for a person without a line stays pending and is
  counted; reopen releases it and approve refuses until prepared again;
  preparing again attaches it once more; removing a swept bonus is refused;
  settings gate and fallback.
- Unit: `lib/kudos.ts` (input, month options, counts), `lib/payroll.ts`
  (net math mirror, totals, CSV columns, actions with `reopened_at`,
  bonus input).
- E2E `bonuses.spec.ts`: settings → bonus → prepare → line shows net →
  reopen → bonus pending again; `kudos.spec.ts`: HR posts on behalf with a
  value → the wall shows the pill → edit → remove; `payroll.spec.ts`
  updated for the new CSV columns.

### 1.4 Review

Five findings fixed. The one that mattered: the lines' audit trigger
redacted `amount` alone, so every prepare would have logged `gross` and
`net` into the activity log that access managers read — the trigger now
redacts every amount column (smoke asserts it). Also: a reopened period's
lines drop the released bonuses at the period's own rate, so the lines and
the CSV never carry a bonus that is pending again (smoke asserts the
recompute); the wall's insert grant is column-level, so nobody forges
"recorded by" or a date from Home (smoke asserts the refusal); an edit
that keeps the day keeps its clock, and `posted_by` changes only when the
giver does (smoke asserts a self-posted kudos stays the giver's after HR
fixes a typo).

## 2. Out of scope

The real MK contribution rules (replaces the estimate when decided);
pro-rating; bonuses in a currency the person is not paid in (they wait,
visibly, until a period in that currency has a line for them).
