# Plan 047: Checklists — per person, editable per company, worked as a checklist

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: L / **Risk**: LOW–MEDIUM (touches the plan
  page every hire and departure goes through) / **Depends on**: 046
- **Category**: product. Second slice of plan 045. What the stakeholders
  asked for in one sentence: a checkbox list per person for onboarding and
  offboarding, with what · who · where on every line, that HR can shape per
  company. Personnel has the richer model (owner role, phase, due offset,
  critical, evidence) but the template was editable only through SQL, the
  plan page turned a checkbox into four buttons, and a scheduled departure
  could not be cancelled.

## 1. What changes

### 1.1 Database (migration 0040)

- **Template editing** through RPCs, so the rules live in one place:
  `upsert_template_task(p)` (add or change a line; the company's own
  template is created by copying the holding default the first time —
  copy-on-write, so the default stays the default), `retire_template_task`
  (a line leaves the list; running checklists keep their copy),
  `reorder_template_tasks(template, ids[])`. Gate: `tasks.assign` in the
  company; the holding default stays admin-only (as 0006 already says).
- **Richer defaults**, seeded holding-wide, the US items dropped:
  - Onboarding: Employment agreement signed (HR, −3, critical, evidence) ·
    Personal, ID and bank details collected (HR, −3, critical — ticks itself
    when the private row holds the national ID and the bank account) · Work
    account and email created (IT, −1, critical) · Starter kit issued (IT,
    −1, critical) · System access granted (IT, −1) · Welcome note sent with
    policies (HR, −2) · First-day details shared (HR, −2) · Handover sent to
    accounting and IT (HR, −1) · Team introduction (manager, 0) · First 1:1
    with manager (manager, +2) · Policies acknowledged (the person, +5).
  - Offboarding: Resignation / termination letter on file (HR, −10,
    evidence) · Handover documented and accepted (manager, −5, critical) ·
    Exit conversation held (HR, −2) · Equipment returned and return form
    signed (IT, 0, critical) · Accounts and access removed (IT, 0, critical)
    · Departure sent to accounting (HR, 0) · Final pay and documents issued
    (HR, +3) · Manager sign-off (manager, +1).
  - Existing template rows are replaced in place (same template ids), so
    checklists already running are untouched (they hold copies).
- **`add_plan_task(plan, title, owner_role, due_date, critical)`** — the
  one-off line on one person's checklist; `tasks.assign` in the company.
- **`cancel_departure(period, reason)`** — clears the dates, closes the
  offboarding plan as cancelled with the reason (its return tasks close
  with it; nothing was reserved for a departure, so nothing to release),
  keeps the departure details row for history; `departure.start`. Refused
  once the person is former.
- **Self-ticking**: a trigger on `person_private_details` marks the
  "Personal, ID and bank details collected" task done on the open
  onboarding checklist once both the national ID and the account number are
  on file (`template_task_key = 'private_details'` — template tasks gain a
  `key` so hooks find their line by meaning, not by title).

### 1.2 App

- **Settings → Checklists** (company profile, `tasks.assign` holders and
  admins): the onboarding and offboarding templates as editable lists —
  title, owner, when (phase + days), critical, evidence — add, edit inline,
  move up / down, retire. A company without its own template shows the
  holding default with "Customise for {company}" that copies it.
- **The plan page as a checklist**: one checkbox per line (tick = done,
  untick = reopen), progress bar, owner and due date on the line, a small
  menu for Skip / Block / Unblock (dialogs), an **Add task** line at the
  bottom. Same page for both kinds.
- **Onboarding and Offboarding pages**: each checklist expands inline with
  the same checkboxes; filters by company (`CompanyFilter`) and owner
  ("what is on IT this week").
- **Cancel departure** next to Mark as former on the employment row (reason
  dialog); the row returns to employed, the plan shows as cancelled.

### 1.3 Tests

- Smoke `0040`: the holding default is edited by admin only; a company HR
  edit creates the company copy and leaves the default; a checklist started
  after the edit uses the company list; a running checklist is untouched by
  the edit; retire hides the line from new checklists; `add_plan_task`
  gated; `cancel_departure` restores the period, cancels the plan, refused
  after former, a second schedule starts a fresh plan; the private-details
  task ticks itself when both fields land.
- Unit: `checklists.ts` (progress, grouping, template diff, defaults for a
  new line, filters).
- E2E `checklists.spec.ts`: HR customises the company onboarding template
  (adds a line) → adds an employee → the checklist shows the new line →
  tick / untick / add task / skip with a reason → schedule a departure →
  cancel it → the person is employed again.

### 1.4 Review

Four findings fixed: an edit of a holding-default line is matched to the
company's copy by key (or title) after the copy is made, so the first edit
lands; a refused tick snaps the checkbox back; "Line saved" versus "Line
added" is decided before the edit state is cleared; a line added back under
the title of a retired keyed line regains its key, so its self-ticking hook
finds it again (smoke asserts it).

## 2. Out of scope

The handover sends and their self-ticking (048), the starter kit and the
return form (049), the welcome note and policy acknowledgement ticks (050).
The default lines for those exist now; their hooks come with their slices.
