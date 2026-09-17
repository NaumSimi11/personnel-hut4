# Plan 048: The handover — who · where · what, green or red

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: L / **Risk**: MEDIUM (personal data leaves
  the database by email — every field is gated twice) / **Depends on**: 047
- **Category**: product. Third slice of plan 045. The maintainer's ask, in
  his words: "we need to have a list — who to send, where to send, what to
  send. So the accountants get the bank account number; if we send that
  information we should see that green, otherwise red, but also be able to
  edit it manually." The IT guy is the existing `it_owner` workflow role.

## 1. What changes

### 1.1 Database (migration 0041)

- **`handover_recipients`** — per company (holding-wide rows with no
  company are the default underneath): `label` ("Accountant", "IT"),
  `kind` (`role` → a workflow-owner role key such as `it_owner` /
  `hr_owner`; `person` → a named colleague; `email` → an external
  address), `role_key` / `person_id` / `email`, `events text[]` (which of
  `hire_confirmed` · `onboarding_finished` · `departure_scheduled` ·
  `marked_former`), `fields text[]` (from the catalogue below), `trusted`
  (may receive sensitive fields), `active`. RLS: read `tasks.view` in the
  company; write `tasks.assign` — and putting a **sensitive field** on a
  recipient needs `personal.view` (for national ID, bank account, birth
  date, address, personal email, phone) or `salary.view` (for salary) in
  that company, checked by the RPC `save_handover_recipient(p)`. The
  holding default is admin-only. Seeded defaults (holding-wide, inactive
  address to fill for the accountant):
  - IT (`role it_owner`, hire confirmed + departure scheduled + marked
    former) ← name, work email, position, department, start date, end
    date, starter kit
  - Accountant (`email`, address empty → *missing* until filled, trusted;
    hire confirmed + marked former) ← name, national ID, bank account,
    salary, start date, end date
  - Manager (`person` = the period's manager, hire confirmed) ← name,
    position, department, start date
- **Field catalogue** (`app.handover_fields()`): name, work_email,
  personal_email, phone, position, department, location, company,
  start_date, end_date, manager, employment_type, national_id, bank_account,
  salary, starter_kit, equipment_held. Sensitive: personal_email, phone,
  national_id, bank_account, salary, birth_date, address. A non-trusted
  recipient never receives a sensitive field even if configured — the
  snapshot builder strips it and the send says so.
- **`handover_sends`** — one row per recipient per event per person:
  `person_id`, `company_id`, `plan_id` (the checklist it belongs to, when
  any), `recipient_id`, `recipient_label`, `event`, `to_email` (resolved at
  send time: the role owner's work email, the person's work email, or the
  address), `fields jsonb` (the snapshot: `{key: {label, value}}`),
  `missing text[]` (configured fields that are empty on the record),
  `status` (`pending` → `sent` / `failed` / `missing` / `manual`),
  `error`, `attempts`, `sent_at`, `marked_by`, `dedupe_key`. RLS: read
  `tasks.view` (the values inside are what was sent — readers of the card
  are HR; the snapshot is audited by field name only), write only through
  RPCs.
- **Events** raise sends through triggers: `hire_confirmed` when an
  onboarding plan is created from an application (plans insert with
  `employment_period_id` whose application exists) — and, since a plain
  add is also a hire for these purposes, on any onboarding plan insert;
  `onboarding_finished` when a plan flips to completed; `departure_scheduled`
  on an offboarding plan insert; `marked_former` when the period's status
  becomes former. `app.raise_handover(event, person, company, plan)` builds
  one send per active recipient whose `events` contain it, snapshotting the
  allowed fields; when a required field is empty the send is `missing` with
  the names. A cancelled departure marks its pending sends `cancelled`.
- **RPCs**: `resend_handover(send)` (rebuilds the snapshot from the record
  now and requeues — this is the "fill it and resend"), `mark_handover_sent(send)`
  (`manual`, records who), `retry_handover(send)` (a failed one back to
  pending), `handover_fields()` (the catalogue with labels and sensitivity
  for the settings UI). All need `tasks.assign` in the company.
- **Self-ticking**: the `handover` (onboarding) and `handover_out`
  (offboarding) checklist lines tick when every send of that plan's event
  is `sent` or `manual` — trigger on `handover_sends`.
- **IT requests join the notification layer**: `companies.it_notification_email`
  (empty = the IT owner's own address; nobody → skipped); created → IT;
  blocked → HR owner; done → the requester. Through `app.notify`.
- **Server**: `POST /api/handover/deliver` sends pending `handover_sends`
  as a table email (label per field, sensitive ones included only when the
  row carries them — the database already decided), same Resend path, same
  retry rule, outcome on the row. The existing deliver kick in the app also
  kicks this queue.

### 1.2 App

- **Settings → Handover** (company profile; `tasks.assign`): the recipients
  as cards — label, who (role / colleague / address), when (event chips),
  what (field checkboxes; sensitive ones with a lock, greyed unless the
  recipient is trusted and the viewer holds the capability), active. Add,
  edit, remove. The holding default shown underneath, read-only for
  non-admins.
- **Handover card** on the checklist page (both kinds): one row per send —
  recipient, address, a traffic light (green sent / manual, red failed /
  missing with the missing fields named, grey pending), *Resend*, *Mark as
  sent*, *Retry*, and *What was sent* (expands the snapshot). "Fill it and
  resend": the missing names link to the private card on the record.
- **`companies.it_notification_email`** on the Notifications settings
  panel next to the HR one.

### 1.3 Tests

- Smoke `0041`: a hire produces one send per recipient with exactly that
  recipient's fields; the accountant with no address is `missing` (address)
  and with an empty bank account is `missing` (bank account); filling both
  and `resend_handover` makes it `pending` with the value; a non-trusted
  recipient configured with the national ID never receives it (stripped);
  a `personal.view`-less HR cannot put the national ID on a recipient;
  `mark_handover_sent` is `manual` with who; the `handover` line ticks when
  every send is green; `departure_scheduled` sends to IT with the equipment
  held; `marked_former` sends to the accountant; a cancelled departure
  cancels pending sends; IT request created → the IT owner is notified at
  the company's IT address.
- Server unit: `renderHandoverEmail` (a table per field, escaped, no field
  the row does not carry).
- Unit: `lib/handover.ts` (traffic light per status, missing names, field
  gating for the settings form, recipient summary).
- E2E `handover.spec.ts`: configure the accountant address and fields →
  add an employee with no bank account → the Handover card shows the
  accountant red with "bank account" → fill the private card → Resend →
  green (or "queued", mail not configured) → Mark as sent on IT → the
  "Handover sent" line ticks itself.

### 1.4 Review

Done by hand (the multi-agent review hit the session limit). Fixed: the
send counter used `if found` after `on conflict do nothing`, now
`get diagnostics`; the Handover card lists the plan's company only, so a
person employed in two companies does not see both companies' sends on one
checklist. Checked and left: a plan with no employment period (the seeded
E2E case) lands every employment field in `missing`; Resend on a green
send rebuilds and requeues on purpose; the E2E cleanup restores the
company's default state.

## 2. Out of scope

The starter kit and equipment PDFs (049) — the `starter_kit` field renders
the kit items once 049 exists, "not set" until then; the welcome note (050).
