# Plan 049: Equipment for the holding, assigned to anyone, with signed forms

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: L / **Risk**: MEDIUM (touches the asset
  RLS and adds server-side document generation) / **Depends on**: 048
- **Category**: product. Fourth slice of plan 045. The maintainer: "the
  equipment now is based on company level? We need to have it globally. We
  need to assign on each employee equipment; we need to make a template
  deals — example when we do the offboarding, auto generated PDF is
  generated with the dedicated equipment to return, and so on."

## 1. What changes

### 1.1 Database (migration 0042)

- **The holding pool**: `assets.company_id` becomes nullable — null is the
  holding's pool. RLS: a pool asset is read by anyone holding `it.view`
  anywhere and written by anyone holding `it.assign` anywhere; a company
  asset keeps its company gate. `reserve_asset` no longer requires
  employment in the asset's company, only a current employment somewhere;
  `issue_asset` / `return_asset` / `cancel_reservation` accept the pool
  (`app.can_work_asset(asset, cap)`). `assets` unique tag is per company or
  per pool (`unique nulls not distinct (company_id, asset_tag)`).
  `app.add_equipment_tasks` (0025) lists every asset the leaver holds,
  pool included.
- **Starter kit**: `companies.settings -> 'starter_kit'` (a text array;
  the holding's row is the default underneath) read through
  `app.starter_kit_for(company)`. Default seeded on the holding: Laptop,
  Monitor, Keyboard & mouse, Badge / access card, Phone, Desk & chair,
  Software licences. `set_starter_kit(company, items[])` — `it.assign` or
  admin. When an onboarding checklist starts, `app.open_starter_kit(plan)`
  creates one `it_requests` row of kind `onboarding` with
  `requested_systems = [{item, issued_at, asset_id}]` linked to the
  `starter_kit` checklist line (`plan_task_id`); `issue_kit_item(request,
  index, asset?)` ticks one item (optionally naming a registered asset,
  which is reserved + issued to the person in one go) and, when every item
  is issued, marks the request done and the line done. `add_kit_item(request,
  item)` for the extra thing per hire. The handover's `starter_kit` field
  (0041) reads the kit request: "Laptop ✓, Monitor ✓, Phone —".
- **Document categories**: `equipment_handover` and `equipment_return`
  (person-scoped). `record_generated_document(person, company, category,
  title, storage_path, size, supersedes)` — called by the server with the
  caller's identity, so `uploaded_by` is the person who asked.
- **Return form on departure**: `schedule_departure` (0040 body) calls
  `app.request_return_form(plan)` which inserts a `document_requests`-free
  marker: a `generated_documents` queue row (`kind = 'equipment_return'`,
  person, plan, status pending). The server picks the queue up on the next
  deliver kick, renders the PDF from the record, stores it, records the
  document and marks the row done. So the form appears on the person's
  Documents within seconds of scheduling, without the browser holding the
  PDF library. The same queue serves the handover form on `issue_asset`
  (`kind = 'equipment_handover'`, one per issue, all assets held on it) and,
  in 050, the welcome note.
- The `return_form` checklist line ticks itself when a document of category
  `equipment_return` with `version >= 2` exists for the plan's person and
  company (the signed scan uploaded as a new version).

### 1.2 Server

- `pdfmake` (pure JS, works on Vercel functions) with the built-in Roboto
  vfs. `renderEquipmentForm(kind, data)` → PDF buffer: company header,
  person, date, a table (tag · type · model · serial · condition), signature
  lines for the person and IT; MK and EN headings side by side (both
  languages on one page — the open question resolved conservatively).
- `POST /api/documents/generate` (signed-in; drains `generated_documents`
  the caller may see: `tasks.view` or `it.view` in the company) — the
  existing deliver kick calls it too, so a scheduled departure produces the
  form without a click.

### 1.3 App

- **Equipment page** in the main nav (`/equipment`, visible to anyone with
  `it.view` anywhere): the register across the holding with the shared
  `CompanyFilter` plus "Holding pool"; add an asset to the pool or a
  company; reserve / issue / return / cancel as before, the person picker
  listing everyone currently employed anywhere. The company profile's
  Equipment tab stays for that company's assets and IT requests.
- **Settings → Starter kit** (chips; add / remove; the holding default shown
  when the company has none).
- **Starter kit card** on the onboarding checklist: the kit request's items
  as checkboxes with an optional asset picker per item, "Add item".
- **Documents card** shows generated forms like any document; the signed
  scan goes up as a new version through the existing "New version" flow.

### 1.4 Tests

- Smoke `0042`: a pool asset is visible to Bea (it.view in B) and to Alex
  (Company A); Bea reserves it for someone employed in A (allowed now) and
  issues it; a company-A asset stays invisible to Bea; the leaver's return
  tasks include the pool asset; the kit request is created with the
  holding default (7 items) when the company has none, the company's own
  list when set; issuing every item ticks the line; the extra item; the
  handover `starter_kit` value; the return-form queue row on departure and
  the tick on a version-2 return document; the categories exist.
- Server unit: the PDF renderer produces a PDF (magic bytes) containing the
  tag and the person's name; a queue row without assets still renders.
- Unit: `lib/equipment.ts` additions (pool label, kit item shaping, form
  summaries).
- E2E `equipment-pool.spec.ts`: add an asset to the pool from the Equipment
  page → issue it to someone in another company → the handover form appears
  under their Documents → schedule their departure → the return form
  appears → issue the kit items on a fresh hire's checklist → the line ticks.

### 1.5 Review

Four findings fixed. A regenerated form used to supersede the previous
unsigned one and so came out as version 2, which the "return form signed"
tick reads as the signed scan — now a fresh form archives the old one and
is version 1 again, only a person's upload makes version 2 (smoke asserts
it). Failed queue rows are retried on later kicks up to five attempts
(`attempts` column) instead of being stranded behind a unique dedupe key.
The generator selects only the kinds it can make, so a welcome-note row
(050) never fills the batch. The starter kit card kicks the generator when
a named asset was issued.

## 2. Out of scope

The welcome note (050) — the queue and the generator are ready for it.
Per-language template text editing in the UI (the forms carry both
languages); document_templates as a table waits until the welcome note
needs editable text.
