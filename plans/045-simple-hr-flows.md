# Plan 045: Simple HR flows — one employee record, checklists per person, the handover to IT and accounting, holding-wide equipment with signed forms, policies and the welcome note

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: XL, delivered as six slices (046–051) /
  **Risk**: MEDIUM (touches the hire → onboard → offboard spine) /
  **Depends on**: 044
- **Category**: product. The stakeholders' second prototype
  (`docs/files 1/hr-system.html`) shows how they *think* about HR work:
  one employee form with everything on it, a checkbox list per person
  for onboarding and offboarding, IT told when someone is hired. Personnel
  stores more than the prototype does but makes people enter it in six
  places, keeps its checklists in a template nobody can edit from the
  app, knows nothing about who must be told what when someone joins or
  leaves, ties equipment to one company, and has no welcome note.
- **Maintainer decisions (16 Sep)**: net pay as in the prototype for now
  (tax % + flat deductions per company; to be replaced later) · every
  checklist is per person — what, who, where · an IT owner role, and on
  hire / onboarding done an automatic email to whoever must know, with
  a list of *who · where · what* per recipient (the accountant gets the
  bank account), green when sent, red when not, editable by hand ·
  equipment holding-wide, assignable to any employee, with generated
  PDFs for handover and return · "our entry is worse" confirmed: fix the
  entry, keep the model.

## 1. The honest comparison

### 1.1 Employee data

The prototype's employee form (17 fields, one screen) against Personnel:

| Prototype field | Personnel today | Where | Verdict |
| --- | --- | --- | --- |
| Full name, work email | `people.full_name`, `work_email` | Add person | ok |
| Position | `employment_periods.job_title` | Add person | ok |
| Company | `employment_periods.company_id` (5 companies, transfers) | Add person | ok — richer |
| Department | `employment_periods.department_id` (per company) | **not on Add person**; Schedule change only | gap: ask at creation |
| Annual salary | `compensation_records` (amount, currency, basis, proposer ≠ approver) | Compensation card, separate act | gap: ask at creation (as a proposal) |
| Status | pre-start / active / former, derived | — | ok — richer |
| Start / end date | `start_date`, `end_date`, `last_working_date` | Add person / Schedule departure | ok |
| Date of birth | `person_private_details.birth_date` | Private details card | ok |
| Personal phone, personal email | `people.phone`, `personal_email` | **no edit UI at all** (only Add person inserts; nothing updates) | **gap** |
| Home address | `person_private_details.address` (jsonb) | Private details card, one line | ok |
| Emergency contact name / relationship / phone | `emergency_contacts` jsonb `{name, phone}` | Private details card | gap: **relationship missing** |
| Attachments (contracts) | Documents module (categories, versions, requests) | Documents card | ok — richer |
| Salary history | compensation records with effective dates | Compensation card | ok — richer |
| — (needed by the accountant) | bank account, national ID (we keep only a hint) | — | **gap** — see 046 |
| — | preferred name, manager, location, employment type, avatar, notes | scattered | ok |

Defects found on the way:

- `PrivateDetailsCard` renders only for admins or the person themselves
  (`visible = auth.isAdmin || auth.personId === props.personId`), although
  RLS admits every `personal.view` holder. Company HR sees nothing.
- `people` basics (name, preferred name, personal email, phone) cannot be
  edited anywhere after creation.
- Add person does **not** start an onboarding plan; only Confirm hire (from
  a candidate) does. Everyone added by hand or imported has no checklist.
- Departments and locations can be added by platform admins only
  (`CompanyStructurePanel`), so HR cannot even create the department a
  new hire belongs to.

**Conclusion**: the model is not poorer — the *entry* is. One form that
captures everything at once, one place to edit it, and the plan starting
by itself.

### 1.2 Onboarding

| Prototype | Personnel today | Gap |
| --- | --- | --- |
| Fixed 8-item checklist per hire (offer letter, I-9 / tax forms, IT account, equipment, access, orientation, payroll & benefits, first 1:1) | Template of 5 tasks with owner role, phase, due offset, critical, evidence → a plan per person with dated, owned tasks | ours is richer per task but **shorter**, and not editable from the app |
| Checkbox + progress bar | Plan page with Complete / Skip / Block / Reopen per task, reasons asked through `window.prompt` | heavier than a checkbox; no ad-hoc task |
| Every employee gets the checklist | Only Confirm hire creates a plan | gap |
| Onboarding tab shows every checklist inline | Onboarding page lists plans with progress; tasks one click away | inline expand |
| Policy library (title + summary), auto-included in the welcome note | Policies per company or holding-wide with summary, file, versions, publish, acknowledgements, Home queue row | richer, but **no default library, no welcome note** |
| New hire sees nothing | My workspace → My onboarding (read-only), My tasks, policies to acknowledge | ok |

### 1.3 Offboarding

| Prototype | Personnel today | Gap |
| --- | --- | --- |
| Pick employee + last working day → 8-item checklist, progress, Cancel offboarding, Mark as Terminated | Schedule departure (end date, last day, restricted reason) → plan of 5 owned tasks + one IT task per registered asset; Mark as former; Offboarding page | **no cancel**; template not editable; list shorter (no letter on file, no final pay and documents, no manager sign-off); **no return form** |

### 1.4 Materials / equipment

| Prototype | Personnel today | Gap |
| --- | --- | --- |
| Free-text items per employee, quick-add chips, issued toggle with date | Asset register **per company** (`assets.company_id`, RLS by `it.view` in that company, reserving requires the person to be employed in the asset's company); reserve / issue / return; IT requests with `requested_systems` jsonb, made by hand | rigorous but heavy; **company-bound**; nothing requested at hire; no signed handover or return document |

### 1.5 Telling people (IT, accounting, manager)

| Prototype | Personnel today | Gap |
| --- | --- | --- |
| Hire → IT request queued with items; one IT contact email; "Email IT", mark sent | `it_requests` with assignee / status and Home rows for `it.assign` holders; workflow owner role `it_owner` per company already exists (Settings → Workflow owners); the notification layer (0034) covers leave, hiring, candidates, documents — **not IT, not accounting**; no IT inbox address; nobody tells the accountant anything | **gap** — the handover matrix (048) |

### 1.6 Everything else in the prototype

| Prototype | Personnel | Note |
| --- | --- | --- |
| Companies on employees | employment periods per company | ok |
| Raises + compensation history | compensation records | ok |
| Bonuses swept into the next run; tax % + flat benefits → net | payroll period snapshots gross only | 051, prototype's model for now |
| Kudos values, admin kudos management | kudos wall (044) | 051 |
| Attachments on applicants | application files, bulk CVs | ok |

### 1.7 The entry experience — why it feels worse

Counted, not felt:

- **14 places still ask through `window.prompt` / `window.confirm`**
  (leave entitlement and adjustments — three prompts in a row for one
  balance —, skip / block reasons on plans, reject reasons on jobs,
  archive a policy, remove a holiday, cancel a change, mark as former).
  Hiring (042) already replaced its prompts with dialogs; the rest of the
  app did not follow. A browser prompt cannot validate, cannot show
  context, cannot be styled, and is the single biggest reason the app
  feels rougher than the prototype.
- **Adding one employee with everything = 5 screens**: Add person (6
  fields) → record → Private details card → Compensation card → Schedule
  change for the department → Equipment card. The prototype: one form.
- **Nothing can be edited where it is shown**: name / emails / phone have
  no edit at all; department, title, manager only through "Schedule a
  change" (correct for history, wrong for a typo — 0037 fixed that for
  dates only).
- **The plan page makes a checkbox into four buttons** (Complete, Skip,
  Block, Reopen) and asks reasons through prompts.
- **CSV import** takes 10 columns (no personal email, DOB, address,
  emergency contact, bank, salary), so the richest entry route is also
  incomplete.
- **Structure is admin-only** (departments, locations), so HR hits a wall
  in the second field of the form.

The rule for every slice below: **one job, one screen; every reason in
a dialog; every field editable where it is shown; the database keeps the
history — the person never fights it.**

## 2. What we build — six slices

Each slice is its own numbered plan when executed, with the repo's
workflow: migration + `local-verify.sh` → live → types → unit + E2E →
review → commit → README + development plan.

### 046 — The employee record (one form, one place to edit) + the end of prompts

**Add employee**: one dialog, four sections on one screen (collapsing on
phones), every field optional except name, company, title and start date:

1. *Identity* — full name, preferred name, work email, personal email,
   personal phone, photo.
2. *Employment* — company, job title, department (add one inline if it is
   missing — HR may), location, employment type, manager, start date.
3. *Personal & emergency* (`personal.view` holders) — date of birth, home
   address, national ID number, bank name + account number (IBAN /
   transaction account), emergency contact name / relationship / phone,
   notes. The national ID and bank account are what the accountant needs
   (048); they are stored under `personal.view`, redacted in the audit
   log like salaries (`app.audit_redacted`), and never leave the database
   except through a recorded handover send.
4. *Pay* (`salary.propose` holders) — amount, currency, basis, effective
   from the start date; saved as a **proposed** compensation record, the
   approver decides as today.

One RPC `create_employee(jsonb)` writes person, employment, private
details and the pay proposal in one transaction and **starts the
onboarding plan** from the company's template. Confirm hire opens the
same dialog pre-filled from the application (the prototype's "convert to
employee"). CSV import gains the same columns.

**Edit where it is shown**: *Edit details* on the record for the basics;
the private details card edits every field above and renders for every
`personal.view` holder; job title / department / manager get a
*Correct* next to *Schedule a change* (0037's in-place correction,
extended to those columns) for typos versus real changes.

**Prompts gone**: every `window.prompt` / `window.confirm` (14) becomes a
small dialog with a reason field and the object's context — one shared
`ReasonDialog` component. HR may add departments and locations
(`employment.edit`), not only admins.

- Migration 0038: `create_employee`; `person_private_details.national_id`,
  `bank_account` jsonb `{bank, account_number}` under redacted audit;
  `correct_employment` extended to title / department / location /
  manager; structure RLS opened to `employment.edit`.
- Tests: smoke (one call, all rows, plan started, pay proposed not
  approved, private part refused without `personal.view`, national ID and
  bank never in the audit payload); unit (form schema, import columns);
  E2E add with everything → record shows every section → edit basics →
  correct a title → HR grant holder sees the private card → a reason
  dialog replaces a prompt (leave adjustment).

### 047 — Checklists: per person, editable per company, worked as a checklist

A checklist is always **one person's**: their plan, with *what* (the
task), *who* (owner — HR, IT, manager, the person, or a named colleague)
and *where* (the company, the location, the due date) on every line.
The template is only where a new checklist starts from.

- **Settings → Checklists** (per company; the holding-wide default
  underneath): the onboarding and offboarding templates as editable
  lists — title, owner role, when (phase + days before/after the start or
  last day), critical, needs evidence; add, reorder, retire. On the
  existing `task_templates` / `template_tasks`; a company without its own
  template inherits the holding's; editing a template never touches
  checklists already running.
- **Richer defaults**, seeded holding-wide:
  - Onboarding: Employment agreement signed (HR, −3, critical, evidence) ·
    Personal, ID and bank details collected (HR, −3, critical — ticks
    itself when the fields in 046 are filled) · Work account and email
    created (IT, −1, critical) · Starter kit issued (IT, −1, critical —
    049) · System access granted (IT, −1) · Welcome note sent with policies
    (HR, −2 — 050) · First-day details shared (HR, −2) · Handover sent to
    accounting and IT (HR, −1 — ticks itself, 048) · Team introduction
    (manager, 0) · First 1:1 with manager (manager, +2) · Policies
    acknowledged (the person, +5 — ticks itself, 050).
  - Offboarding: Resignation / termination letter on file (HR, −10,
    evidence) · Handover documented and accepted (manager, −5, critical) ·
    Exit conversation held (HR, −2) · Equipment returned and return form
    signed (IT, 0, critical — 049) · Accounts and access removed (IT, 0,
    critical) · Departure sent to accounting (HR, 0 — ticks itself, 048) ·
    Final pay and documents issued (HR, +3) · Manager sign-off (manager,
    +1).
  - The US items (I-9, COBRA, benefits enrollment) are dropped.
- **The plan page as a checklist**: one checkbox per line (tick = done,
  untick = reopen), progress bar, owner and due date on the line, a small
  menu for Skip / Block / Attach evidence (dialogs, not prompts), an
  **Add task** line for the one-off item. Same page for onboarding and
  offboarding.
- **Onboarding and Offboarding pages** show each person's checklist
  inline (expand), ticking works there too; filter by company and owner
  ("what is on IT this week").
- **Cancel a scheduled departure**: `cancel_departure(period)` clears the
  dates, closes the plan as cancelled, keeps the reason in history,
  releases reservations; a button next to *Mark as former*.
- Migration 0039: template RPCs (`upsert_template_task`,
  `retire_template_task`, per-company copy-on-write), `add_plan_task`,
  `cancel_departure`, seeds, the self-ticking task hooks.
- Tests: smoke (company template overrides holding default; a checklist
  started after an edit uses the new list; a running checklist is
  untouched by the edit; cancel restores the period and releases
  reservations); E2E edit template → add an employee → checklist shows the
  new line → tick, untick, add task, skip with reason dialog → schedule
  departure → cancel.

### 048 — The handover: who · where · what, green or red

What the maintainer described: when someone is hired (and when a
checklist finishes, and when someone leaves), the people who must know
get an email with exactly the information they need, and HR sees per
recipient whether it went.

- **Settings → Handover** (per company, holding default underneath): a
  list of **recipients** — each is a workflow-owner role (IT owner, HR
  owner — the "IT guy" is the existing `it_owner`), a named colleague, or
  an **external address** (the accountant) — with, per recipient:
  *when* (hire confirmed · onboarding finished · departure scheduled ·
  marked former) and *what*: a checklist of fields from the record —
  name, personal email, phone, position, department, company, start /
  end date, manager, national ID, bank account, salary, starter kit,
  equipment held. Sensitive fields carry a lock: only a recipient marked
  as trusted for them (the accountant) may receive them, and only holders
  of `personal.view` / `salary.view` may put them on a recipient.
  Defaults seeded: IT owner ← name, work email, position, start date,
  starter kit; accountant (address to fill) ← name, national ID, bank
  account, salary, start / end date; manager ← name, position, start
  date.
- **Sends**: on the event, one `handover_sends` row per recipient with
  the field snapshot, sent through the 0034 delivery route (Resend), with
  status **sent** (green), **failed** (red), **missing** (red — a required
  field is empty: "bank account not on file → fill it") or **manual**
  (HR sent it another way and ticked it). On the person's checklist a
  *Handover* card shows the recipients as a traffic light with *Resend*,
  *Mark as sent*, *Edit fields for this send*; the "Handover sent" task
  ticks itself when every recipient is green.
- **IT requests** join the notification layer: `companies.it_notification_email`
  (empty = the IT owner's own address); created → IT, blocked → HR owner,
  done → requester.
- Migration 0040: `handover_recipients`, `handover_sends` (snapshot jsonb,
  status, sent_at, error), triggers on plans (started / finished) and
  employment periods (departure scheduled / former), `app.notify` for
  `it_requests`.
- Tests: smoke (a hire produces one send per recipient with only that
  recipient's fields; a missing bank account is *missing*, filling it and
  resending makes it *sent*; a non-trusted recipient never gets the
  national ID even if configured — the trigger strips it; the task ticks
  when all green); server unit (email rendering per field set); E2E hire
  → Handover card red for the accountant → fill bank account → resend →
  green → task ticked.

### 049 — Equipment for the holding, assigned to anyone, with signed forms

- **Holding-wide register**: assets belong to the holding by default
  (`company_id` nullable = holding pool; a company-owned asset is still
  possible), visible and assignable by anyone with `it.assign` in **any**
  company; reserving no longer requires employment in the asset's
  company. The Equipment page moves from the company profile to the main
  nav (*Equipment*), with a company filter (the shared `CompanyFilter`).
- **Starter kit** per company (Settings → Starter kit chips: Laptop,
  Monitor, Keyboard & mouse, Badge / access card, Phone, Desk & chair,
  Software licences — editable). When a checklist starts, one IT request
  of kind `onboarding` is created with the kit as items
  (`[{item, issued_at, asset_id}]`); IT ticks items as issued, optionally
  linking a registered asset; when every item is issued, "Starter kit
  issued" ticks itself. Extra items per hire, free text.
- **Forms as PDFs** (the "template deals"): generated on the server
  (`pdfmake`, pure JS — runs on Vercel functions without a browser) from
  the record and the assignment rows, stored in Documents under the
  person with a new category, downloadable, and the signed scan uploaded
  back as a new version of the same document:
  - *Equipment handover form* — on issue: person, company, date, the
    items with tag / model / serial / condition, signature lines.
  - *Equipment return form* — generated automatically when a departure is
    scheduled, listing everything the person holds (assets + kit items),
    condition column, signature lines; the "Equipment returned and return
    form signed" task needs the signed version as evidence.
  - The same generator serves the welcome note (050) and, later, other
    letters (employment confirmation, salary certificate) — one
    `document_templates` table with the text per company and language
    (MK / EN), placeholders filled from the record.
- Migration 0041: `assets.company_id` nullable + RLS for the pool,
  `reserve_asset` / `issue_asset` gates, kit tables, `document_templates`,
  `generate_document(kind, person)` server route recording the document.
- Tests: smoke (an asset in the pool is assignable to someone employed in
  any company; a company asset stays company-gated; kit issue completes
  the task; departure creates the return form document); server unit (PDF
  contains the items; a placeholder never renders raw); E2E add asset to
  the pool → issue to someone in another company → handover PDF in
  Documents → schedule departure → return form appears → upload signed →
  task done.

### 050 — Policies as a library, and the welcome note

- **Default library** seeded holding-wide as drafts with summaries: Code
  of Conduct · Time off & leave · Remote & hybrid work · IT & data
  security · Anti-harassment & equal opportunity · Expenses &
  reimbursement. HR edits the summary, writes the text in the app or
  attaches a file (`body` column — a policy need not be a PDF), publishes;
  per-company overrides as today.
- **"Policies acknowledged"** ticks itself when the person has
  acknowledged every published policy that applies to them (trigger on
  `policy_acknowledgements`).
- **Welcome note**: generated from the record — name, position,
  department, company, start date, manager, the company's *first-day
  details* (Settings: where to come, when, who to ask for, what to bring)
  and the published policies with links to read them in My workspace.
  Preview on the checklist, then **Send** (Resend, to the personal email
  by default — the work mailbox may not exist on day −2 — or the work
  email; *Copy* / mailto when mail is not configured). Sending ticks
  "Welcome note sent" and is recorded as a notification row; re-send
  allowed, the card says when it last went. Also produced as a PDF
  through 049's generator for the file.
- The invitation email (temporary password) links to the same policies.
- Migration 0042: `policies.body`, company first-day fields, the
  acknowledgement trigger, seeds.
- Tests: smoke (auto-tick on the last acknowledgement; holding-wide policy
  applies everywhere unless overridden); unit (`welcomeNote()` text); E2E
  publish → add an employee → preview shows the policy → send (delivery
  reported) → task ticked → the hire acknowledges → "Policies
  acknowledged" ticks itself.

### 051 — Kudos values, bonuses and net pay (the prototype's model, for now)

- **Kudos values**: `kudos_values` holding-wide (name, description,
  active) with the five defaults (Teamwork, Ownership, Customer focus,
  Innovation, Integrity); optional `value_id` on kudos, a pill on the
  wall; a *Kudos* admin view — month filter, counts per value, post on
  someone's behalf with a date, edit, remove.
- **Bonuses**: `payroll_items` (person, company, amount, currency, reason,
  date, `period_id` when swept) included as extra lines when a period is
  prepared; reopening a period releases them (the prototype's rule).
- **Net pay, prototype model**: per company `tax_rate_percent` and
  `deductions_flat` (Settings → Payroll); each prepared line gets `bonus`,
  `gross` (base + bonus), `tax`, `deductions`, `net`; period totals show
  gross and net; the export carries both. Marked in the UI as "estimate —
  statutory contributions are the accountant's"; replaced when the real
  MK rules are decided.
- Migration 0043.
- Tests: smoke (a pending bonus lands in the next period once; net =
  gross − tax − deductions; reopen releases the bonus); E2E bonus → prepare
  → line shows net → reopen → bonus pending again.

## 3. Order and why

046 first: every other slice hangs off a complete record, an edit that
works, and a checklist that starts on its own. 047 second: the checklists
are what the stakeholders asked for in one sentence. 048 makes the hire
reach IT and accounting by itself, with the traffic light. 049 gives
equipment a home for the whole holding and the signed forms. 050 closes
the loop with the person (policies, welcome). 051 is the prototype's
Admin and Payroll tabs.

## 4. Open questions for the maintainer (none block 046–047)

1. The accountant: internal person or external address? (048 supports
   both; the default seed needs the address.)
2. Which fields the accountant gets — the seed above, or more (address,
   employment type)?
3. Form language for the PDFs: MK, EN, or both (049 templates are per
   language).
4. Starter kit defaults per company, or one list for the holding?
