# Plan 046: The employee record — one form, one place to edit, no more prompts

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: L / **Risk**: MEDIUM (touches the hire
  path: `confirm_hire` becomes a wrapper) / **Depends on**: 045 (programme),
  0037 (`correct_employment`)
- **Category**: product. First slice of plan 045. The model was never poorer
  than the prototype's — the *entry* was: five screens to add one employee,
  no edit for name / emails / phone, the private card hidden from Company
  HR, no checklist for anyone added by hand, structure admin-only, and
  33 browser prompts and confirms across the app.

## 1. What changes

### 1.1 Database (migration 0038)

- `person_private_details.national_id` (4–32 chars) and `bank_account`
  jsonb `{bank, account_number}` — what the accountant will receive (048).
  `national_id_hint` keeps the last four digits by trigger. The emergency
  contact carries `relationship` (jsonb, no schema change).
- The table is now **audited by field name only**: `app.audit_fields_only`
  writes which columns changed, never a value. 0005 left it unaudited for
  the same reason; a row that says "bank_account changed by X at T" is the
  minimum the accountant hand-over (048) needs.
- **Structure for HR**: `departments` / `locations` accept inserts and
  updates from `employment.edit` holders in that company; holding-wide rows
  (no company) stay admin-only.
- **`app.start_onboarding_plan(person, company, period, start)`** — the
  template lookup and task copy lifted out of `confirm_hire`; idempotent per
  period.
- **`create_employee(jsonb)`** — one transaction: person (or the existing
  person a candidate's email matches — a rehire), first employment,
  private details (needs `personal.view`), a proposed compensation record
  (needs `salary.propose`; via `propose_compensation`), the onboarding plan
  (`start_onboarding`, default true). With `application_id` it is the hire:
  offer stage only, idempotent, application → hired with the timeline
  event, the job's company decides. `confirm_hire` is now a wrapper over it
  with its old signature and messages.
- **`correct_employment`** gains `p_fields jsonb` (`department_id`,
  `location_id`, `manager_id`; a key present with `null` clears, an absent
  key keeps) validated through `app.validate_employment_change`;
  `employment_corrections` keeps old / new for the three.
- **`import_people`** takes the new columns (`personal_email`, `birth_date`,
  `address`, `national_id`, `bank_name`, `bank_account_number`,
  `emergency_contact_name` / `_relationship` / `_phone`, `salary_amount` /
  `salary_currency` / `salary_basis`), writes every row through
  `create_employee`, refuses the file up front when a private or salary
  column is present without the capability, and starts the checklist for
  people whose start date is today or later (a backfill gets none).

### 1.2 App

- **`AddEmployeeDialog`** replaces `AddPersonDialog` and `ConfirmHireDialog`:
  four sections on one screen — Identity · Employment (department added
  inline) · Personal & emergency (shown to `personal.view` holders in the
  chosen company) · Pay (shown to `salary.propose` holders). Opened plain
  from People & access (any `employment.edit` holder, not only admins) or
  pre-filled from an application (Confirm hire). Success screen links to
  the record and the checklist. Photo stays on the record (`AvatarUpload`).
- **`EditPersonDialog`** — Edit details on the record: full name, preferred
  name, work email, personal email, phone (RLS `can_edit_person`).
- **`PrivateDetailsCard`** renders for every `personal.view` holder over the
  person (was admin / self only) and edits every field incl. national ID,
  bank, relationship.
- **`CorrectEmploymentDialog`** corrects department, location and manager.
- **`ReasonDialog`** + `lib/dialogs.ts` (a promise queue) + `AppDialogs`
  mounted once in `App.vue`: `confirmAction()` and `askReason()` replace
  all 33 `window.confirm` / `window.prompt` sites (leave entitlement asks
  the number and the reason in one dialog).
- **`CompanyStructurePanel`** lets `employment.edit` holders add / archive.
- **`ImportPeopleDialog`** / `lib/importPeople.ts`: the new columns.

### 1.3 Tests

- Smoke `0038`: Bea (Company HR in B) adds a department in B, refused in A;
  create_employee with everything by Bea → person, period, private row,
  proposal (not approved), plan with tasks; the audit holds the field names
  and never the national ID or account number; Omar with `employment.edit`
  only → private part refused, pay refused, plain add succeeds and starts
  the plan; `start_onboarding=false` → no plan; duplicate work email
  refused; `confirm_hire` wrapper still hires; `correct_employment` sets and
  clears department / manager with old / new kept, another company's
  department refused; import with a bank column by someone without
  `personal.view` refused before any write.
- Unit: `employeeForm.ts` (schema, payload, section gating, prefill from an
  application, messages), `dialogs.ts` (queue), `employmentCorrection.ts`
  (fields diff), `importPeople.ts` (columns).
- E2E `employee-record.spec.ts`: add with everything → record shows every
  section → edit basics → correct the department → an HR grant holder (not
  admin) sees the private card → a reason dialog replaces the leave
  entitlement prompt. Every spec that answered a browser prompt now answers
  the in-app dialog (`e2e/support/dialogs.ts`).

### 1.4 Review (migration 0039)

The medium review's findings that live in the database: one person per
work email is a partial unique index (the insert catches the violation,
the hire path included); clearing the national ID clears its hint; a hire
attaches to an existing person by candidate email only when that person
holds no open employment; a hire always starts the checklist whatever the
date; `app.check_employee(p, company)` returns every shape problem as
sentences and both `create_employee` and the import preview use it, so
they cannot disagree; an index on `plans (employment_period_id)`. In the
app: one `companyStructure` lib (loader, add department, messages) for
the three dialogs and the panel; one `personBasicsInput` schema for Add
and Edit; one `PrivateDetailsFields` component for the dialog and the
card; the dialog answers "no" on any close so the queue never wedges;
`autofocus` instead of a selector; a filled section the viewer may not
send is refused, never dropped; Enter in the inline department field adds
the department; reference data loaded once per mount.

## 2. Out of scope

Checklist editing and the plan page as a checkbox list (047), the hand-over
sends (048), photos inside the add dialog.
