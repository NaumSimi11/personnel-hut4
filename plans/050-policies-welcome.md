# Plan 050: Policies as a library, and the welcome note

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW / **Depends on**: 049
- **Category**: product. Fifth slice of plan 045. The prototype ships a
  policy library and includes the policies in a welcome note; Personnel
  has the richer policy model (versions, acknowledgements per version,
  holding-wide or per company) but no default library, no text-only
  policy, and nothing that welcomes the person.

## 1. What changes

### 1.1 Database (migration 0043)

- **`policies.body`** (text, optional): a policy may be written in the app
  instead of attached; `publish_policy` accepts a body or a file (one of
  the two must be there). A new version of a text policy is a new body.
- **Default library**, seeded holding-wide as drafts with summaries and a
  short body each, so HR edits and publishes rather than starting blank:
  Code of Conduct · Time off & leave · Remote & hybrid work · IT & data
  security · Anti-harassment & equal opportunity · Expenses &
  reimbursement. Seeded once (`on conflict` on title + null company).
- **"Policies acknowledged" ticks itself**: `app.tick_policies(person)` marks
  the `policies` line done when every published policy that applies to the
  person (holding-wide + their company's) is acknowledged at its current
  version — trigger on `policy_acknowledgements` insert and on
  `publish_policy` (a new version un-ticks nothing already done; the
  checklist line is history, but a running checklist re-checks).
- **First-day details** per company: `companies.settings -> 'first_day'`
  `{where, when, ask_for, bring}`; `set_first_day_details(company, p)` —
  `tasks.assign` or admin; `first_day_details(company)` (holding fallback).
- **The welcome note**: `app.welcome_note_text(person, period)` builds the
  note from the record — greeting, position, department, company, start
  date, manager, the first-day details, the published policies that apply
  (title + summary, "read and acknowledge them in My workspace"), signed by
  the HR owner. `send_welcome_note(plan, to)` (`tasks.assign`; `to` =
  `personal` default or `work`): inserts a `notifications` row for the
  person with the note as the body and the chosen address (through the
  0034 queue, so the delivery route and its outcome apply), queues a
  `welcome_note` generated document (0042 queue) for the file, ticks the
  `welcome_note` line, and records `plans.welcome_sent_at` / `_to`.
  Re-sending is allowed; the card says when it last went. The invitation
  email (temp password) is unchanged (out of scope: it lives in the
  server's access route).

### 1.2 Server

- `renderWelcomeNote(data)` (pdfmake, same engine as 049) → PDF;
  `/api/documents/generate` handles `welcome_note` through
  `welcome_note_data(queue_id)`.

### 1.3 App

- **Policies panel**: a policy may have a body — "Write it here" textarea
  on add and on a new version; Open shows the body in a dialog when there
  is no file. My workspace's policy card renders the body inline.
- **Settings → First day** (where to come, when, who to ask for, what to
  bring).
- **Welcome note card** on the onboarding checklist: preview of the text,
  "Send to personal email / to work email", "Copy" (clipboard, for when
  mail is not configured), when it last went and to where; the PDF appears
  under the person's documents.

### 1.4 Tests

- Smoke `0043`: the six drafts exist holding-wide; a text policy publishes
  without a file and refuses without either; the `policies` line ticks when
  the last applicable policy is acknowledged and not before; a company
  policy counts only for that company's people; first-day details saved by
  HR and read with the holding fallback; the welcome note text carries the
  name, start date, first-day details and the published policies; sending
  creates the notification to the personal address, queues the PDF and
  ticks the line; `to = work` uses the work address; no personal address →
  the notification is skipped and the call says so.
- Server unit: the welcome note PDF renders (magic bytes).
- Unit: `lib/welcome.ts` (address choice, preview lines).
- E2E `welcome.spec.ts`: HR writes a text policy and publishes it → sets the
  first-day details → adds an employee → the welcome card previews the
  policy and the details → Send → the line ticks, the notification row
  exists with the personal address, the PDF is generated → the person signs
  in and acknowledges → "Policies acknowledged" ticks itself.

### 1.5 Review

Five findings fixed. The one that mattered: 0041's recipient gate checked
capabilities only for fields being added, so HR without personal.view
could redirect a trusted recipient's national ID and bank account to any
address — redirecting now needs the capability for every sensitive field
the recipient keeps (smoke asserts it; redefined here since 0041 is live).
Also: the note's month is no longer blank-padded (`FMMonth`); a multi-line
notification body keeps its paragraphs in the email; the card says
"queued" or "failed" as the delivery run reported instead of "sent"; the
read-only RPCs `first_day_details`, `starter_kit` and `handover_fields`
are revoked from anon like every other one.

## 2. Out of scope

Editing the note's wording per company (a `document_templates` table) —
the note is built from the record; the first-day details are the
per-company text. Kudos values, bonuses, net pay (051).
