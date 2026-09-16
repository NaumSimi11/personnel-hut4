# Plan 045: Simple HR flows — the employee record, checklists, starter kit, policies and the welcome note

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: XL, delivered as five slices (046–050) /
  **Risk**: MEDIUM (touches the hire → onboard → offboard spine) /
  **Depends on**: 044
- **Category**: product. The stakeholders' second prototype
  (`docs/files 1/hr-system.html`) shows how they *think* about HR work:
  one employee form with everything on it, and a checkbox list for
  onboarding and offboarding. Personnel already stores more than the
  prototype does, but spreads it over six cards and three dialogs, keeps
  its checklists in a template nobody can edit from the app, and has no
  welcome note, no starter kit and no automatic word to IT. This plan
  closes that gap without giving up what the prototype lacks: owners,
  due dates, audit, per-company access.

## 1. The honest comparison

### 1.1 Employee data

The prototype's employee form (17 fields, one screen):

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
| Personal phone, personal email | `people.phone`, `personal_email` | **no edit UI at all** (only Add person inserts, nothing updates) | **gap** |
| Home address | `person_private_details.address` (jsonb) | Private details card, one line | ok |
| Emergency contact name / relationship / phone | `emergency_contacts` jsonb `{name, phone}` | Private details card | gap: **relationship missing** |
| Attachments (contracts) | Documents module (categories, versions, requests) | Documents card | ok — richer |
| Salary history | compensation records with effective dates | Compensation card | ok — richer |
| — | preferred name, manager, location, employment type, avatar, national id hint, notes | scattered | ok |

Two defects found on the way:

- `PrivateDetailsCard` renders only for admins or the person themselves
  (`visible = auth.isAdmin || auth.personId === props.personId`), although
  RLS allows every `personal.view` holder. HR with the right grant sees
  nothing.
- `people` basics (name, preferred name, personal email, phone) cannot be
  edited anywhere in the app after creation.

**Conclusion**: the data model is not poorer — the *entry* is. One form
that captures everything at once (and one place to edit it) is what the
prototype has and we lack.

### 1.2 Onboarding

| Prototype | Personnel today | Gap |
| --- | --- | --- |
| Fixed 8-item checklist per hire (offer letter, I-9 / tax forms, IT account, equipment, access, orientation, payroll & benefits, first 1:1) | Template of 5 tasks with owner role, phase, due offset, critical, evidence → a plan per hire with dated, owned tasks | our list is richer per task but **shorter**, and not editable from the app |
| Checkbox + progress bar | Plan page with Complete / Skip / Block / Reopen per task, Finish plan | heavier than a checkbox; no ad-hoc task |
| Every employee gets the checklist | Only **Confirm hire** creates a plan; **Add person does not** | gap |
| Onboarding tab shows the checklist inline for everyone in progress | Onboarding page lists plans with progress; tasks are one click away | inline expand |
| Policy library (title + summary) | Policies per company or holding-wide, with summary, file, versions, publish, acknowledgements, Home queue row | ok — richer, but **no default library** |
| Welcome note generated from the record + policies, mailto, mark sent | nothing | **gap** |
| New hire sees nothing (no login in the prototype) | My workspace → My onboarding (read-only) + My tasks + policies to acknowledge | ok |

### 1.3 Offboarding

| Prototype | Personnel today | Gap |
| --- | --- | --- |
| Pick employee + last working day → 8-item checklist, progress, Cancel offboarding, Mark as Terminated | Schedule departure (end date, last day, restricted reason) → plan of 5 owned tasks + one IT task per asset held; Mark as former; Offboarding page | **no cancel**; template not editable; list shorter (no letter on file, no final pay/documents, no manager sign-off) |

### 1.4 Materials (starter kit)

| Prototype | Personnel today | Gap |
| --- | --- | --- |
| Free-text items per employee, quick-add chips (Laptop, Monitor, Keyboard & mouse, Badge, Phone, Desk & chair, Software licences), issued toggle with date | Asset register: an asset must exist (tag, type, model, serial) before it can be reserved / issued / returned; IT requests with `requested_systems` jsonb, kinds onboarding / role_change / departure / manual — created by hand only | rigorous but heavy; **nothing is requested automatically at hire** |

### 1.5 IT notifications

| Prototype | Personnel today | Gap |
| --- | --- | --- |
| Hire → IT request queued with requested items; IT contact email per workspace; "Email IT", mark sent | `it_requests` exist with assignee / status / blocked reason and Home queue rows for `it.assign` holders; **not created at hire; the notification layer (0034) does not cover them; no IT inbox address** | **gap** |

### 1.6 Everything else in the prototype

| Prototype | Personnel | Note |
| --- | --- | --- |
| Companies on employees | employment periods per company | ok |
| Raises + compensation history | compensation records | ok |
| Bonuses swept into the next payroll run; tax % + flat benefits → net | payroll period snapshots gross only | decision open — see plan 050 |
| Kudos values, admin kudos management | kudos wall (044) | plan 049 |
| Attachments on applicants | application files, bulk CVs | ok |

## 2. What we build — five slices

Each slice is its own numbered plan when executed, with the repo's
workflow: migration + `local-verify.sh` → live → types → unit + E2E →
review → commit → README + development plan.

### 046 — The employee record (one form, one place to edit)

**Add employee** becomes one dialog with four sections, all on one screen
(sections collapse on phones):

1. *Identity* — full name, preferred name, work email, personal email,
   personal phone, photo (optional).
2. *Employment* — company, job title, department (of that company),
   location, employment type, manager, start date.
3. *Personal & emergency* (`personal.view` holders only; skippable) —
   date of birth, home address, emergency contact name / relationship /
   phone, notes.
4. *Pay* (`salary.propose` holders only; skippable) — amount, currency,
   pay basis, effective from start date. Saved as a **proposed**
   compensation record; the approver decides as today.

One RPC `create_employee(p_person jsonb, p_employment jsonb, p_private
jsonb, p_pay jsonb)` writes person, employment, private details and the
pay proposal in one transaction and **starts the onboarding plan** from
the company's template (today only Confirm hire does that). Confirm hire
opens the same dialog pre-filled from the application (as the prototype's
"convert to employee" does).

**Edit** on the person record: an *Edit details* dialog for the basics
(name, preferred name, emails, phone) — the missing piece — and the
private details card gains the relationship field and renders for every
`personal.view` holder.

- Migration 0038: `create_employee`; `emergency_contacts` keeps its jsonb
  shape with `relationship` added; no other schema change.
- Tests: smoke (one call, all rows, plan started, pay proposed not
  approved, private part refused without `personal.view`); E2E add →
  record shows every section → edit basics → private details visible to
  an HR grant holder.

### 047 — Checklists you can edit, and use like a checklist

- **Settings → Checklists** (per company; the holding-wide default
  underneath): the onboarding and offboarding templates as editable
  lists — title, owner (HR / IT / manager / the person), when (phase +
  days before/after the start or last day), critical, needs evidence;
  add, reorder, retire. Uses the existing `task_templates` /
  `template_tasks` tables; a company without its own template falls back
  to the holding's.
- **Richer defaults**, seeded holding-wide (existing plans untouched):
  - Onboarding: Employment agreement signed (HR, −3, critical, evidence) ·
    Personal, ID and bank details collected (HR, −3) · Work account and
    email created (IT, −1, critical) · Starter kit issued (IT, −1,
    critical — see 048) · System access granted (IT, −1) · Welcome note
    sent with policies (HR, −2 — see 049) · First-day details shared (HR,
    −2) · Team introduction (manager, 0) · First 1:1 with manager
    (manager, +2) · Policies acknowledged (the person, +5).
  - Offboarding: Resignation / termination letter on file (HR, −10,
    evidence) · Handover documented and accepted (manager, −5, critical) ·
    Exit conversation held (HR, −2) · Equipment returned (IT, 0, critical —
    one per asset, as today) · Accounts and access removed (IT, 0,
    critical) · Final pay and documents issued (HR, +3) · Manager sign-off
    (manager, +1).
  - The US items (I-9, COBRA, benefits enrollment) are dropped; Hut4 is
    North Macedonia.
- **The plan page as a checkbox list**: one checkbox per task (tick =
  done, untick = reopen), progress bar, owner and due date on the line,
  a small menu for Skip / Block / Evidence, an **Add task** line for the
  one-off item. Same page for onboarding and offboarding.
- **Onboarding and Offboarding pages** show each plan's checklist inline
  (expand), as the prototype's tabs do, with the same tick behaviour.
- **Cancel a scheduled departure**: `cancel_departure(period)` clears
  the dates, closes the plan as cancelled, keeps the reason in history,
  reopens equipment reservations; a button next to *Mark as former*.
- **Mark as former** stays explicit (the prototype's *Mark as
  Terminated*), and the plan's open tasks stay finishable.
- Migration 0039: template editing RPCs (`upsert_template_task`,
  `retire_template_task`, per-company copy-on-write from the holding
  default), `add_plan_task`, `cancel_departure`, new seeds.
- Tests: smoke (company template overrides holding default; a plan
  started after an edit uses the new list; cancel restores the period and
  releases reservations; last-admin style guard: a critical template task
  cannot be retired while plans in progress reference it — no, they keep
  their copies; assert that); E2E edit template → start a hire → checklist
  shows the new task → tick, untick, add task → schedule departure →
  cancel.

### 048 — Starter kit and the word to IT

- **Settings → Starter kit** (per company): the chips — Laptop, Monitor,
  Keyboard & mouse, Badge / access card, Phone, Desk & chair, Software
  licences — editable.
- When an onboarding plan starts, one **IT request** of kind `onboarding`
  is created automatically for the hire with the company's kit as items
  (`requested_systems` becomes `[{item, issued_at, asset_assignment_id}]`),
  linked to the "Starter kit issued" task. IT ticks items as issued (with
  an optional link to a registered asset — the register stays for what
  matters: laptops, phones); when every item is issued the task completes.
  Extra items can be added per hire (free text), as in the prototype.
- When a departure is scheduled, the kind `departure` request lists what
  the person holds (assets + kit items) to take back — today only
  registered assets get tasks.
- **IT notifications** join the 0034 layer: `companies.it_notification_email`
  (the prototype's IT contact email; empty = each `it.assign` holder's
  own address); triggers on `it_requests`: created → IT ("Set up Ana Kova
  · starts 1 Oct · Laptop, Monitor…"), blocked → HR contact, done → the
  requester. The delivery status shows on the request, as everywhere.
- Migration 0040.
- Tests: smoke (plan start creates the request with the kit; issuing the
  last item completes the task; notifications rows for IT holders and
  the inbox address); E2E hire → Equipment shows the kit → tick items →
  task done → bell on the IT side.

### 049 — Policies as a library, and the welcome note

- **Default library** seeded holding-wide as drafts with summaries: Code
  of Conduct · Time off & leave · Remote & hybrid work · IT & data
  security · Anti-harassment & equal opportunity · Expenses &
  reimbursement. HR edits the summary, attaches the text (file or
  in-app text — `body` column added so a policy need not be a PDF) and
  publishes; per-company overrides as today.
- **"Policies acknowledged"** onboarding task completes itself when the
  person has acknowledged every published policy that applies to them
  (trigger on `policy_acknowledgements`).
- **Welcome note**: generated from the record — name, position,
  department, company, start date, manager, the company's *first-day
  details* (new Settings fields: where to come, at what time, who to ask
  for, what to bring) and the list of published policies with links to
  read them in My workspace. Preview on the plan, then **Send** (Resend,
  to the personal email — the work mailbox may not exist yet — or the
  work email; falls back to *Copy* / mailto when mail is not configured),
  which completes the "Welcome note sent" task and records the delivery
  as a notification row. Re-send allowed; the note says when it last went.
- When the invitation (temporary password) goes out later, the credential
  email links to the same policies — the person reads them where they
  will acknowledge them.
- Migration 0041: `policies.body`, company first-day fields, the
  acknowledgement trigger, seeds.
- Tests: smoke (auto-complete on the last acknowledgement; holding-wide
  policy applies to every company unless overridden); unit
  (`welcomeNote()` text); E2E publish a policy → start a hire → preview
  shows it → send (delivery reported) → task ticked → the hire
  acknowledges → "Policies acknowledged" ticks itself.

### 050 — Kudos values, admin kudos; bonuses (decision needed)

- **Kudos values** (prototype's Admin tab): `kudos_values` holding-wide
  (name, description, active) with the five defaults (Teamwork,
  Ownership, Customer focus, Innovation, Integrity); optional `value_id`
  on kudos, shown as a pill on the wall; a *Kudos* admin view — month
  filter, counts per value, post on someone's behalf with a date, edit,
  remove. Small.
- **Bonuses / one-off payroll items**: `payroll_items` (person, company,
  amount, currency, reason, date, `period_id` when swept) included as
  extra lines when a period is prepared; deleting a period releases them
  (the prototype's rule). Medium.
- **Net pay** (tax % + flat deductions → net): **not** in this plan
  unless the maintainer wants Personnel to compute net. The prototype's
  flat percentage is a demo; MK contributions and tax are the
  accountant's calculation. The exported gross register stays the
  deliverable until told otherwise.

## 3. Order and why

046 first: every other slice hangs off a complete employee record and a
plan that starts on Add person. 047 second: the checklists are what the
stakeholders asked for in one sentence. 048 and 049 make the checklist
do work on its own (IT told, kit issued, policies read, note sent). 050
last; its second half waits on a decision.

## 4. What the maintainer decides

1. Net pay in Personnel, or gross register only (050).
2. The default checklists above — anything Hut4 does differently
   (e.g. a separate "Bank account for salary" item, a "Health insurance
   registration" item for MK employers).
3. Whether the welcome note goes to the personal email by default.
