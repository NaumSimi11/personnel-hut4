# Попис: the annual equipment count, the holding-wide register, and transfers between companies

Design, 17 September 2026. Written for whoever implements this and for the
maintainer reviewing it before they do.

## Why

Equipment across the holding lives in one spreadsheet,
`Spisok na oprema vo site kompanii 2.xlsx`, with a sheet per company. The app's
asset register holds nothing at all, so the spreadsheet is the only record.

Once a year a *пописна комисија* — an inventory commission of a few named
people — walks the offices, sees what exists and who has it, and signs a report
stating that what they found matches the accounting records. That report is a
legal artefact, not an internal note.

The spreadsheet shows the cost of doing this outside the app:

| Sheet | Items | Counted | Shape |
| --- | --- | --- | --- |
| Synami | 148 | 31.12.2025 | 6 columns, 139 `√` |
| Hut 4 | 41 | 31.12.**2024** | 4 columns, reordered, 35 `√` |
| Liquiditas | 16 | never | 3 columns, no commission, no date |

Three layouts for one process, one company a year behind, one never formally
counted. Nothing accumulates: each year rebuilds the list rather than
confirming it.

## What this delivers

1. **The register moves into the app.** The ~205 spreadsheet rows become assets.
2. **Попис**: open a count for a company and a year, walk the list, record what
   you found, add what was bought, close it and get the signed report.
3. **One holding-wide view** of every asset regardless of company.
4. **Transfer between companies**, with a printable transfer document.

### Not in scope

- Depreciation, book values, or anything else the accountants own. The
  commission attests that the count matches accounting; it does not *do*
  accounting.
- Counting anything that is not an asset (consumables, stationery).
- Retiring the spreadsheet automatically. The import runs once; the maintainer
  decides when the spreadsheet stops being authoritative.

### Size

This is more than one slice of work. The natural order is **register and import
first** (there is nothing to count until the assets exist), then **the count**,
then **transfers**, which depend on neither. The implementation plan should
split it that way rather than treat it as one delivery.

## The existing ground

The schema already fits, and the design leans on it rather than inventing
alongside it.

- `assets` (migration 0004, amended by 0042) — `company_id` is nullable, and
  null means the holding pool. `asset_tag`, `type_key`, `model`,
  `serial_number`, `status`, `note`.
- `asset_assignments` — who holds what, with `issued_at` / `returned_at`.
- `asset_types` — `laptop, monitor, phone, accessory, software_license`.
- RLS via `app.can_see_asset(company_id)` and `app.can_work_asset(company_id,
  cap)`: holding-pool assets answer to `it.view` / `it.assign` held *anywhere*,
  a company's assets to the capability *at that company*.
- The Equipment page already has an **Everywhere** filter.
- The server already renders PDFs with pdfmake in Macedonian and English
  (equipment handover and return forms, plan 049) and files them as documents.

`magacin` — the warehouse — is not a new concept. It is an asset with no open
assignment: `status = 'available'`, nobody holding it.

## Data model

One migration, `0045_popis.sql`.

### Two new asset types

```sql
insert into public.asset_types (key, label, is_physical) values
  ('desktop', 'Desktop PC', true),
  ('vehicle', 'Возила / Vehicles', true)
on conflict (key) do nothing;
```

`Софтвери` maps to the existing `software_license`, which is already
`is_physical = false` — software cannot be seen on a desk, so the count treats
it as a documentary check rather than a physical one.

### The count itself

```sql
create table public.popis_rounds (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  year int not null,
  status text not null default 'open'
    check (status in ('open', 'closed', 'cancelled')),
  period_from date,
  period_to date,
  statement text,               -- the attestation paragraph, editable per round
  opened_by uuid references public.people(id),
  opened_at timestamptz not null default now(),
  closed_by uuid references public.people(id),
  closed_at timestamptz,
  report_document_id uuid references public.documents(id),
  unique (company_id, year)
);
```

One count per company per year, enforced by the database. A cancelled round
frees the year.

```sql
create table public.popis_members (
  popis_id uuid not null references public.popis_rounds(id) on delete cascade,
  person_id uuid not null references public.people(id),
  ordinal int not null,         -- 1., 2., 3. as the report prints them
  primary key (popis_id, person_id)
);
```

The commission, in the order they sign. The report prints them numbered, as
the Hut 4 sheet does.

```sql
create table public.popis_lines (
  id uuid primary key default gen_random_uuid(),
  popis_id uuid not null references public.popis_rounds(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  expected_holder_id uuid references public.people(id),   -- null = magacin
  expected_status text not null,
  outcome text not null default 'pending'
    check (outcome in ('pending', 'found', 'moved', 'missing', 'added')),
  found_holder_id uuid references public.people(id),      -- null = magacin
  note text,
  counted_by uuid references public.people(id),
  counted_at timestamptz,
  unique (popis_id, asset_id)
);
```

`expected_*` is a snapshot taken when the round opens, so the report can show
what the register claimed *before* the count, which is the whole point of
counting. The outcomes are exactly the four things that can happen:

| Outcome | Means | On close |
| --- | --- | --- |
| `found` | There, with the expected holder | Nothing changes |
| `moved` | There, but someone else has it, or it is back in magacin | Reassign to `found_holder_id` |
| `missing` | Not found. `note` is required | `assets.status = 'lost'` |
| `added` | Bought this year, not on the list | The asset is created up front, so nothing more |

`added` lines are created by the counter through **Add item**, which creates the
asset *and* its line in one call, so a new purchase is registered and counted in
one action.

### Transfers

```sql
create table public.asset_transfers (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  from_company_id uuid references public.companies(id),   -- null = holding pool
  to_company_id uuid references public.companies(id),     -- null = holding pool
  reason text,
  transferred_by uuid not null references public.people(id),
  transferred_at timestamptz not null default now(),
  document_id uuid references public.documents(id),
  check (from_company_id is distinct from to_company_id)
);
```

A transfer is a permanent record, never edited. An asset's history then reads:
bought → issued to X → returned to magacin → transferred to Hut 4 → counted in
попис 2026.

### The asset tag collision

`assets` has `unique nulls not distinct (company_id, asset_tag)`. Synami uses
`A001…`, Liquiditas uses `0000001…`, so a transfer can carry a tag into a
company that already uses it.

**The tag does not change.** It is printed on a physical label on the thing
itself, and silently renumbering it would make the label lie. Instead
`transfer_asset` raises a named error when the target company already holds
that tag, and the UI asks the person to give the asset a new tag *before*
transferring — a deliberate act with a physical consequence (relabel it), not a
silent rewrite.

## The import

A one-off script, `server/scripts/import-popis-xlsx.mjs`, run by hand against a
named workbook. Not a migration: it is data, it runs once, and it needs a human
in the loop.

Two passes:

**Pass 1 — read and report.** Parse each sheet, map categories to types, and
resolve holder strings. Write a review file listing every row and how it was
understood. Change nothing.

**Pass 2 — apply.** Only after the maintainer has corrected the review file.

Category mapping (per sheet, since the sheets disagree):

| Sheet heading | `type_key` |
| --- | --- |
| Лаптопи, Laptops | `laptop` |
| Монитори, Monitors | `monitor` |
| Desktop PC | `desktop` |
| Софтвери | `software_license` |
| Мобилни телефони | `phone` |
| Возила | `vehicle` |
| Останати, Останато | `accessory` |

Holder strings resolve in this order:

1. `magacin` (any case) → no holder; the asset sits in the company's warehouse.
2. `<Company> DOOEL` → no holder; the company itself holds it. Recorded in
   `note`, because it is not a person.
3. `Name Surname` → matched against `people.full_name`, case-insensitively.
4. `Name Surname (Hut4)` → the same, with the parenthesised company kept in
   `note`. It records that a Synami asset is used by someone at Hut 4, which is
   what the holding pool exists for and is worth preserving verbatim.
5. Anything else — initials such as `IL`, or a name matching nobody, or matching
   two people — is left **unresolved** and listed in the review file for a human
   to decide.

Rule 5 is the one that matters. `IL` is probably Igor Lestar, and an importer
that acts on "probably" attaches someone's laptop to the wrong person in a
legal document. Unresolved rows import as unassigned with the original string
in `note`, and the review file names every one.

Sheet quirks the parser must handle, because they are real in this workbook:

- Column order differs per sheet; each sheet gets its own column map, keyed by
  header text rather than position.
- Hut 4 has rows where the holder appears in a later column than the header
  implies, and rows carrying a second code (`A050`, `A062`) in a trailing cell.
- Liquiditas has no preamble, no commission and no ticks; it imports as a plain
  register with no count.
- The `√` is not imported. It is evidence of the 2025 count, not a property of
  the asset. Synami's completed count is history; the app starts counting from
  the round the maintainer opens.

## The workflow

### Opening a round

Settings → Equipment, or the Equipment page: **Start попис** for a company and
year. It creates the round, snapshots a line per asset that company owns
(`expected_holder_id`, `expected_status`), and records the commission members
and the period.

Assets in the **holding pool** (`company_id is null`) appear in no company's
round by default. They are counted in whichever round the maintainer chooses,
via an explicit "include holding pool" toggle when opening — otherwise a pooled
laptop is either counted three times or not at all.

### Counting

One page per round, grouped by category exactly as the report prints. Each
line offers three actions and nothing else:

- **✓ Here** — `found`
- **Moved** — pick a person, or *magacin*; sets `moved`
- **Missing** — opens the note dialog, which is required; sets `missing`

Plus **+ Add item** for a purchase not on the list.

Several people count at once. Each line records `counted_by` and `counted_at`,
so two members can work different floors without colliding, and the round shows
progress the way the onboarding plan does: `74 of 148 counted · 6 missing`.

### Closing

**Close попис** is refused while any line is `pending`. On close, in one
transaction:

1. `moved` lines reassign the asset (close the open `asset_assignments` row,
   open a new one, or leave it unassigned for magacin).
2. `missing` lines set `assets.status = 'lost'`.
3. The report renders to PDF and is filed as a document, its id stored on the
   round.
4. The round becomes `closed`. Nothing about it can be edited afterwards; a
   mistake is corrected by a new round, not by rewriting a signed one.

### The report

Server-rendered with pdfmake, Macedonian and English, following the shape the
commission already signs:

```
<Company legal name> - 31.12.<year>
ИЗВЕШТАЈ НА ПОПИСНА КОМИСИЈА ЗА ОСНОВНИ СРЕДСТВА

Пописот на основни средства во <company> е извршен во периодот
од <period_from> до <period_to> година. Комисијата за попис на
основни средства ја констатираше следната состојба:

Лаптопи
ред. бр. | Шифра | Основно средство | Корисник | Забелешка
...

Пописна комисија за основни средства        Потпис:
1. <member>          ______________________
2. <member>          ______________________

Скопје, <closed_at>
```

`Забелешка` prints `√` for `found`, and the note for anything else. The
attestation paragraph comes from `popis_rounds.statement`, seeded with the
wording already in use so it can be amended per round without a code change.

### The transfer document

Same pipeline. From company, to company, the asset with tag, model and serial,
the reason, who authorised it, the date, and a signature line for each side.
Filed against the asset and printable.

## Permissions

Nothing new. The existing capabilities already say the right things:

| Action | Capability |
| --- | --- |
| See a round and its lines | `it.view` (via `app.can_see_asset`) |
| Count a line, add an item | `it.assign` at that company |
| Open, close or cancel a round | `it.assign` at that company |
| Transfer between companies | `it.assign` at **both** companies, or admin |

Platform admins pass every one of these, as they do everywhere else; the table
lists what a non-admin needs.

Requiring the capability at both ends of a transfer is deliberate: moving an
asset into a company is a change to that company's register, and its IT owner
should be able to refuse it.

RLS on the three new tables follows `app.can_see_asset(company_id)` through the
round, exactly as `assets` does.

## Testing

Unit, pure logic, tests first as everywhere else in `app/src/lib`:

- `popis.ts` — the outcome state machine; which outcomes are terminal; whether
  a round may close; progress counts; grouping lines by category in report
  order.
- `popisReport.ts` — the report model: category order, `√` versus note,
  numbering, the commission block.
- `assetTransfer.ts` — tag collision detection, and refusing a transfer to the
  same company.
- `popisImport.ts` — holder-string resolution, every rule above, especially
  that `IL` and an ambiguous name resolve to *unresolved* rather than a guess.

Server: the two PDF renderers, asserting a real generated file.

E2E (`popis.spec.ts`): open a round → count one found, one moved, one missing →
add an item → fail to close with a line pending → close → assert the asset
moved, the missing one is `lost`, and the PDF exists. Plus a transfer with its
document.

The suite runs against production and now refuses without
`E2E_ALLOW_PRODUCTION=true`; this spec does not change that.

## Risks

**The import is the dangerous part.** It writes ~205 rows into a live register
that the commission will later sign a legal document about. It runs in two
passes, changes nothing on the first, and a person reads the review file in
between.

**Unresolved holders are a feature.** Expect a handful. The alternative —
guessing — puts a name on a signed document, which is worse than a blank the
maintainer fills in.

**Hut 4 and Liquiditas will look behind after the import**, because they are:
Hut 4 last counted in 2024, Liquiditas never. That is the register telling the
truth, not a defect.

**Closing is irreversible by design.** A signed count is a record. The recovery
path is a new round, and the UI should say so before the button is pressed.

## Every company counts

All six companies get a round each year, including Praedium and Snowball, which
own nothing today and have no sheet. A company that exists is a company that
counts; owning nothing is a finding, not a reason to skip.

So **a round with no lines is valid and must close cleanly**, producing a report
that states the company holds no assets. This falls out of the rules already
given — closing is refused while a line is `pending`, and zero lines means zero
pending — but it is worth naming, because it is easy to implement a close that
assumes at least one line and fails on an empty round.

## Liquiditas is closing

Liquiditas still exists and counts this year like everyone else. It is expected
to close at some point after that, and when it does its assets do not disappear:
they move to another company in the holding, each one carrying a transfer
document naming who authorised the move and when.

This is the reason transfers are in this design rather than a later one. The
sequence the app has to support, in order:

1. Register what Liquiditas owns — its 16 items — and who holds them. Some
   holders already sit at other companies (`Marko Ivanoski (Hut4)`), which the
   import preserves.
2. Count them this year, with a commission and a signed report, as for any
   other company.
3. When the company closes, transfer each remaining asset out, one document per
   asset, leaving a complete paper trail from Liquiditas' register to whichever
   company receives it.

A closing company is therefore not a special case in the data model. It is the
ordinary transfer path, used once per asset. What it does demand is that
transfers work for an asset that is *currently held by a person*, not only for
one sitting in magacin: the holder does not necessarily change when the owning
company does. `transfer_asset` changes `assets.company_id` and leaves any open
`asset_assignments` row untouched, so a laptop can change hands on paper while
staying in the same person's bag.

## Open

One thing the maintainer should settle before the report is built, which does
not block starting:

**The registered legal names** for the report header — `СИНАМИ ДООЕЛ Скопје` and
`Хут4 Капитал ДООЕЛ Скопје` come from the sheets, but Liquiditas, Praedium,
Snowball and Hut4's own remain unknown. `companies` holds a display name; the
report needs the registered one, so this wants a nullable `legal_name` column
filled in per company, falling back to the display name until it is.
