# Попис slice 1 — the register and the import — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get the holding's ~205 real assets out of `Spisok na oprema vo site kompanii 2.xlsx` and into the app's register, visible across every company, so there is something to count.

**Architecture:** Nothing new is invented. `assets` already has a nullable `company_id` (null = holding pool), `asset_types`, `asset_assignments` and RLS through `app.can_see_asset`. This slice adds the two asset types the spreadsheet needs, a `legal_name` for the report header later, a pure resolution module in `shared/` that turns spreadsheet strings into app concepts, and a two-pass import script that refuses to guess. The Equipment page then shows category and holder so the register is readable holding-wide.

**Tech Stack:** Postgres (Supabase migrations, applied with `supabase/apply-migrations.sh --yes`), TypeScript, Node with `tsx` (the importer is TypeScript so it can share `shared/popisImport.ts`), `openpyxl`-free parsing via the `xlsx`-less route — the script reads the workbook with a small ZIP+XML reader already possible in Node, Vitest (server), Vue 3 + Vite (app).

**Spec:** `docs/superpowers/specs/2026-09-17-equipment-popis-design.md`

## Global Constraints

- **Immutability:** never mutate a parameter or a loaded row; return new objects. Project rule.
- **Files:** 200–400 lines typical, 800 max. Many small focused files.
- **TDD is mandatory:** write the failing test, run it, see it fail, then implement.
- **No `console.log` in app code.** `console.error` for genuine failures is the existing convention. A one-off script printing to stdout is fine and expected.
- **Validation at boundaries** with Zod, the house pattern (`app/src/lib/equipment.ts`, `shared/passwordPolicy.ts`).
- **Migrations are numbered sequentially** and never edited once applied. The next free number is `0045`.
- **The import must never guess a person.** An unresolved holder string imports unassigned with the original text preserved in `assets.note`. This is a correctness requirement, not a nicety: a wrong name reaches a signed legal document.
- **Commit after every task.** Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`). No attribution lines — disabled globally for this user.
- **The `√` marks in the workbook are not imported.** They are evidence of the 2025 count, not a property of an asset.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `supabase/migrations/0045_popis_register.sql` | The two asset types the sheets need, and `companies.legal_name`. |
| `shared/popisImport.ts` | Pure: category heading → `type_key`, holder string → a resolution. No I/O, no database. |
| `server/src/popisImport.test.ts` | Tests for the above, mirroring `server/src/account.test.ts` which tests `shared/passwordPolicy.ts`. |
| `server/scripts/import-popis-xlsx.ts` | The two-pass script: read → review file, then apply. I/O only; all decisions come from `shared/popisImport.ts`. |
| `app/src/pages/EquipmentPage.vue` | Show category and holder in the holding-wide register. |

`shared/` is the right home for the resolution logic because the Node script (`tsx`) and the app (`@shared` Vite alias) both reach it, which is exactly why `shared/passwordPolicy.ts` lives there. Its test lives in `server/src/` because the app's Vitest only collects `src/**/*.test.ts`, while the server's picks up `server/src/**`.

---

### Task 1: The migration

**Files:**
- Create: `supabase/migrations/0045_popis_register.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: `asset_types` rows keyed `desktop` and `vehicle`; `public.companies.legal_name text` (nullable).

- [ ] **Step 1: Write the migration**

```sql
-- 0045_popis_register.sql
-- Попис slice 1: the register the annual count will confirm.
--   1. Two asset types the holding's spreadsheet already uses and the app
--      did not have: Desktop PC and Возила (vehicles). Софтвери maps to the
--      existing software_license, which is already is_physical = false —
--      a licence cannot be seen on a desk, so the count reads it as a
--      documentary check rather than a physical one.
--   2. companies.legal_name: the registered name ("СИНАМИ ДООЕЛ Скопје"),
--      which the попис report must print in its header. The display name
--      ("Synami") is what the app shows everywhere else; a report signed by
--      a commission needs the name on the company's registration. Nullable,
--      and the report falls back to the display name until it is filled in.

insert into public.asset_types (key, label, is_physical) values
  ('desktop', 'Desktop PC', true),
  ('vehicle', 'Vehicles', true)
on conflict (key) do nothing;

alter table public.companies add column if not exists legal_name text;
```

- [ ] **Step 2: Apply it**

**Do not use `supabase/apply-migrations.sh`.** It loops every migration from
0001 with no applied-migrations tracking, and 0001 is not idempotent, so against
an existing database it dies on "relation companies already exists" long before
reaching this file. It is a fresh-database tool.

Apply this one file directly:

```bash
cd /Users/naum/Downloads/files
set -a && . ./.env.local && set +a
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/0045_popis_register.sql
```

Expected: `INSERT 0 2` (or `INSERT 0 0` if re-run) and `ALTER TABLE`.

- [ ] **Step 3: Verify the types exist**

Run:
```bash
set -a && . ./.env.local && set +a
psql "$SUPABASE_DB_URL" -At -c "select key, label, is_physical from public.asset_types order by key;"
```

Expected: rows including `desktop|Desktop PC|t` and `vehicle|Vehicles|t`, alongside the existing `laptop`, `monitor`, `phone`, `accessory`, `software_license`.

- [ ] **Step 4: Verify the column exists**

Run:
```bash
psql "$SUPABASE_DB_URL" -At -c "select column_name from information_schema.columns where table_name='companies' and column_name='legal_name';"
```

Expected: `legal_name`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0045_popis_register.sql
git commit -m "feat: asset types for desktops and vehicles, and a company's registered name (migration 0045)"
```

---

### Task 2: Category headings resolve to asset types

**Files:**
- Create: `shared/popisImport.ts`
- Create: `server/src/popisImport.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `export function assetTypeForHeading(heading: string): string | null` — returns a `type_key` (`'laptop' | 'monitor' | 'desktop' | 'software_license' | 'phone' | 'vehicle' | 'accessory'`) or `null` when the heading is not a category.

- [ ] **Step 1: Write the failing test**

Create `server/src/popisImport.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { assetTypeForHeading } from '../../shared/popisImport.js'

describe('assetTypeForHeading', () => {
  it('maps the Macedonian headings the workbook uses', () => {
    expect(assetTypeForHeading('Лаптопи')).toBe('laptop')
    expect(assetTypeForHeading('Монитори')).toBe('monitor')
    expect(assetTypeForHeading('Desktop PC')).toBe('desktop')
    expect(assetTypeForHeading('Софтвери')).toBe('software_license')
    expect(assetTypeForHeading('Мобилни телефони')).toBe('phone')
    expect(assetTypeForHeading('Возила')).toBe('vehicle')
  })

  it('maps the English headings, because Liquiditas writes them that way', () => {
    expect(assetTypeForHeading('Laptops')).toBe('laptop')
    expect(assetTypeForHeading('Monitors')).toBe('monitor')
  })

  it('treats both spellings of the catch-all as accessories', () => {
    // Synami writes "Останати", Hut 4 writes "Останато".
    expect(assetTypeForHeading('Останати')).toBe('accessory')
    expect(assetTypeForHeading('Останато')).toBe('accessory')
  })

  it('ignores surrounding whitespace and case', () => {
    expect(assetTypeForHeading('  лаптопи  ')).toBe('laptop')
    expect(assetTypeForHeading('LAPTOPS')).toBe('laptop')
  })

  it('returns null for anything that is not a category', () => {
    expect(assetTypeForHeading('Скопје, 31.12.2025')).toBeNull()
    expect(assetTypeForHeading('1. Мите Марков')).toBeNull()
    expect(assetTypeForHeading('')).toBeNull()
  })
})
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd server && npx vitest run src/popisImport.test.ts`

Expected: FAIL — cannot resolve `../../shared/popisImport.js`.

- [ ] **Step 3: Write the implementation**

Create `shared/popisImport.ts`:

```ts
/**
 * Turning the holding's equipment spreadsheet into app concepts.
 *
 * Three sheets, three layouts, two alphabets and a decade of habit. This
 * module holds every decision about what a cell *means*; the import script
 * holds only the reading and the writing. Keeping them apart is what lets
 * the rules be tested without a workbook or a database.
 */

const HEADING_TYPES: ReadonlyArray<readonly [RegExp, string]> = [
  [/^лаптоп|^laptop/i, 'laptop'],
  [/^монитор|^monitor/i, 'monitor'],
  [/^desktop/i, 'desktop'],
  [/^софтвер|^software/i, 'software_license'],
  [/^мобилн|^phone|^telefon/i, 'phone'],
  [/^возил|^vehicle/i, 'vehicle'],
  [/^останат|^other/i, 'accessory'],
]

/** The `type_key` a category heading names, or null if it is not a category. */
export function assetTypeForHeading(heading: string): string | null {
  const text = heading.trim()
  if (!text) return null
  const hit = HEADING_TYPES.find(([pattern]) => pattern.test(text))
  return hit ? hit[1] : null
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `cd server && npx vitest run src/popisImport.test.ts`

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add shared/popisImport.ts server/src/popisImport.test.ts
git commit -m "feat: map the equipment spreadsheet's category headings to asset types"
```

---

### Task 3: Holder strings resolve, and refuse to guess

**Files:**
- Modify: `shared/popisImport.ts`
- Modify: `server/src/popisImport.test.ts`

**Interfaces:**
- Consumes: nothing from Task 2 beyond the file existing.
- Produces:

```ts
export type Holder =
  | { kind: 'warehouse' }                                  // magacin
  | { kind: 'company'; text: string }                      // "Synami DOOEL"
  | { kind: 'person'; personId: string; atCompany: string | null }
  | { kind: 'unresolved'; text: string; reason: 'no match' | 'ambiguous' }

export type KnownPerson = { id: string; full_name: string }

export function resolveHolder(raw: string | null | undefined, people: readonly KnownPerson[]): Holder
```

- [ ] **Step 1: Write the failing test**

Append to `server/src/popisImport.test.ts`:

```ts
import { resolveHolder } from '../../shared/popisImport.js'

const PEOPLE = [
  { id: 'p1', full_name: 'Kristina Cvetanov' },
  { id: 'p2', full_name: 'Marko Ivanoski' },
  { id: 'p3', full_name: 'Keith Attard' },
  { id: 'p4', full_name: 'Igor Lestar' },
  { id: 'p5', full_name: 'Igor Dimkovski' },
  { id: 'dup', full_name: 'Ivan Ivanov' },
  { id: 'dup2', full_name: 'Ivan Ivanov' },
]

describe('resolveHolder', () => {
  it('reads magacin as the warehouse, however it is capitalised', () => {
    expect(resolveHolder('magacin', PEOPLE)).toEqual({ kind: 'warehouse' })
    expect(resolveHolder('Magacin', PEOPLE)).toEqual({ kind: 'warehouse' })
    expect(resolveHolder('  MAGACIN ', PEOPLE)).toEqual({ kind: 'warehouse' })
  })

  it('reads an empty cell as the warehouse', () => {
    expect(resolveHolder('', PEOPLE)).toEqual({ kind: 'warehouse' })
    expect(resolveHolder(null, PEOPLE)).toEqual({ kind: 'warehouse' })
    expect(resolveHolder(undefined, PEOPLE)).toEqual({ kind: 'warehouse' })
  })

  it('recognises a company holding its own asset', () => {
    expect(resolveHolder('Synami DOOEL', PEOPLE)).toEqual({ kind: 'company', text: 'Synami DOOEL' })
    expect(resolveHolder('Liquiditas DOOEL', PEOPLE)).toEqual({ kind: 'company', text: 'Liquiditas DOOEL' })
  })

  it('matches a person by name, ignoring case', () => {
    expect(resolveHolder('Keith Attard', PEOPLE)).toEqual({ kind: 'person', personId: 'p3', atCompany: null })
    expect(resolveHolder('keith attard', PEOPLE)).toEqual({ kind: 'person', personId: 'p3', atCompany: null })
  })

  it('keeps the company noted in brackets, which is the holding pool in use', () => {
    expect(resolveHolder('Marko Ivanoski (Hut4)', PEOPLE)).toEqual({
      kind: 'person', personId: 'p2', atCompany: 'Hut4',
    })
    expect(resolveHolder('Kristina Cvetanov (Kaj IL)', PEOPLE)).toEqual({
      kind: 'person', personId: 'p1', atCompany: 'Kaj IL',
    })
  })

  it('refuses to guess at initials', () => {
    // "IL" is probably Igor Lestar. Probably is not good enough for a name
    // that reaches a signed document.
    expect(resolveHolder('IL', PEOPLE)).toEqual({ kind: 'unresolved', text: 'IL', reason: 'no match' })
  })

  it('refuses a name that matches nobody', () => {
    expect(resolveHolder('Someone Not Here', PEOPLE)).toEqual({
      kind: 'unresolved', text: 'Someone Not Here', reason: 'no match',
    })
  })

  it('refuses a name that matches two people rather than picking one', () => {
    expect(resolveHolder('Ivan Ivanov', PEOPLE)).toEqual({
      kind: 'unresolved', text: 'Ivan Ivanov', reason: 'ambiguous',
    })
  })
})
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd server && npx vitest run src/popisImport.test.ts`

Expected: FAIL — `resolveHolder` is not exported.

- [ ] **Step 3: Write the implementation**

Append to `shared/popisImport.ts`:

```ts
export type Holder =
  | { kind: 'warehouse' }
  | { kind: 'company'; text: string }
  | { kind: 'person'; personId: string; atCompany: string | null }
  | { kind: 'unresolved'; text: string; reason: 'no match' | 'ambiguous' }

export type KnownPerson = { id: string; full_name: string }

/**
 * Who holds an asset, according to one cell of the spreadsheet.
 *
 * The last case is the important one. "IL" is very probably Igor Lestar, and
 * an importer that acts on "very probably" writes the wrong person's name
 * onto a document a commission signs. Anything short of certain comes back
 * unresolved, for a person to decide.
 */
export function resolveHolder(
  raw: string | null | undefined,
  people: readonly KnownPerson[],
): Holder {
  const text = (raw ?? '').trim()
  if (!text || /^magacin$/i.test(text)) return { kind: 'warehouse' }
  if (/\bDOOEL\b|\bДООЕЛ\b/i.test(text)) return { kind: 'company', text }

  const bracket = text.match(/^(.*?)\s*\(([^)]*)\)\s*$/)
  const name = (bracket ? bracket[1] : text).trim()
  const atCompany = bracket ? bracket[2].trim() : null

  const matches = people.filter((p) => p.full_name.trim().toLowerCase() === name.toLowerCase())
  if (matches.length === 1) {
    return { kind: 'person', personId: matches[0].id, atCompany }
  }
  return {
    kind: 'unresolved',
    text,
    reason: matches.length > 1 ? 'ambiguous' : 'no match',
  }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `cd server && npx vitest run src/popisImport.test.ts`

Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add shared/popisImport.ts server/src/popisImport.test.ts
git commit -m "feat: resolve equipment holders from the spreadsheet, leaving anything uncertain for a human"
```

---

### Task 4: Read the workbook into rows

**Files:**
- Modify: `shared/popisImport.ts`
- Modify: `server/src/popisImport.test.ts`

**Interfaces:**
- Consumes: `assetTypeForHeading` (Task 2).
- Produces:

```ts
export type SheetRow = { readonly cells: readonly (string | null)[] }
export type ParsedItem = {
  readonly typeKey: string
  readonly heading: string
  readonly assetTag: string | null
  readonly model: string
  readonly holderText: string | null
}
export function parseSheet(rows: readonly SheetRow[]): ParsedItem[]
```

`parseSheet` takes already-extracted cell values, so it is testable without a workbook. Reading the `.xlsx` itself belongs to the script in Task 5.

- [ ] **Step 1: Write the failing test**

Append to `server/src/popisImport.test.ts`:

```ts
import { parseSheet } from '../../shared/popisImport.js'

const row = (...cells: (string | null)[]) => ({ cells })

describe('parseSheet', () => {
  it('attributes each item to the heading above it', () => {
    const items = parseSheet([
      row('Лаптопи'),
      row('ред. бр.', 'Шифра', 'Основно средство', 'Корисник', 'Забелешка'),
      row('1', 'A001', 'Dell Latitude 5590', 'magacin', '√'),
      row('Монитори'),
      row('1', 'M010', 'Monitor Dell S2721HS', 'Keith Attard', '√'),
    ])
    expect(items).toHaveLength(2)
    expect(items[0]).toMatchObject({ typeKey: 'laptop', assetTag: 'A001', model: 'Dell Latitude 5590', holderText: 'magacin' })
    expect(items[1]).toMatchObject({ typeKey: 'monitor', assetTag: 'M010', model: 'Monitor Dell S2721HS', holderText: 'Keith Attard' })
  })

  it('skips the header row rather than importing it as an asset', () => {
    // "Основно средство" is a column title; it appeared as a holder in a
    // naive first pass over this workbook.
    const items = parseSheet([
      row('Лаптопи'),
      row('Шифра', 'Основно средство', 'Забелешка', 'Корисник'),
      row('1', 'Laptop Dell XPs 13 9310', '√', 'Kristina Cvetanov'),
    ])
    expect(items).toHaveLength(1)
    expect(items[0].model).toBe('Laptop Dell XPs 13 9310')
  })

  it('ignores the tick, which records the last count and not the asset', () => {
    const items = parseSheet([
      row('Лаптопи'),
      row('Шифра', 'Основно средство', 'Корисник', 'Забелешка'),
      row('1', 'A001', 'HP ProBook', 'magacin', '√'),
    ])
    expect(JSON.stringify(items[0])).not.toContain('√')
  })

  it('ignores the closing blocks after the list', () => {
    const items = parseSheet([
      row('Лаптопи'),
      row('Шифра', 'Основно средство', 'Корисник'),
      row('1', 'A001', 'HP ProBook', 'magacin'),
      row('Пописна комисија за основни средства', 'Потпис:'),
      row('1. Мите Марков'),
      row('Скопје, 31.12.2024'),
    ])
    expect(items).toHaveLength(1)
  })

  it('reads a sheet with no code column, leaving the tag empty', () => {
    const items = parseSheet([
      row('Laptops'),
      row('Barcode', 'Model', 'User'),
      row('0000001', 'Berin Trade Mark', 'Liquiditas DOOEL'),
    ])
    expect(items[0]).toMatchObject({ assetTag: '0000001', model: 'Berin Trade Mark', holderText: 'Liquiditas DOOEL' })
  })

  it('returns nothing for a sheet with no categories at all', () => {
    expect(parseSheet([row('Some notes'), row('a', 'b')])).toEqual([])
  })
})
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd server && npx vitest run src/popisImport.test.ts`

Expected: FAIL — `parseSheet` is not exported.

- [ ] **Step 3: Write the implementation**

Append to `shared/popisImport.ts`:

```ts
export type SheetRow = { readonly cells: readonly (string | null)[] }

export type ParsedItem = {
  readonly typeKey: string
  readonly heading: string
  readonly assetTag: string | null
  readonly model: string
  readonly holderText: string | null
}

const TICK = /^[√✓v]$/i
/** Column titles, which vary in order across the three sheets. */
const HEADER_WORDS = /^(ред\.?\s*бр\.?|шифра|основно средство|корисник|забелешка|инв\.?\s*бр\.?|barcode|model|user)$/i
const ORDINAL = /^\d+\.?$/
const CLOSING = /пописна комисија|потпис|скопје,|^\d+\.\s/i

function clean(cells: readonly (string | null)[]): string[] {
  return cells.map((c) => (c ?? '').trim()).filter((c) => c !== '')
}

/**
 * The items in a sheet, each attributed to the category heading above it.
 *
 * A heading is a row with a single cell that names a category. Everything
 * after it, until the next heading, is an item — except the column titles
 * (which differ in order on every sheet, so they are recognised by their
 * words rather than their position) and the commission block at the end.
 */
export function parseSheet(rows: readonly SheetRow[]): ParsedItem[] {
  const items: ParsedItem[] = []
  let heading: string | null = null
  let typeKey: string | null = null

  for (const raw of rows) {
    const cells = clean(raw.cells)
    if (cells.length === 0) continue

    if (cells.length === 1) {
      const found = assetTypeForHeading(cells[0])
      if (found) {
        heading = cells[0].trim()
        typeKey = found
        continue
      }
    }
    if (!typeKey || !heading) continue
    if (cells.some((c) => CLOSING.test(c))) continue
    if (cells.every((c) => HEADER_WORDS.test(c))) continue

    // Drop the leading ordinal and the tick; what remains is the item.
    const body = cells.filter((c) => !TICK.test(c))
    const withoutOrdinal = body.length > 1 && ORDINAL.test(body[0]) ? body.slice(1) : body
    if (withoutOrdinal.length === 0) continue

    const looksLikeTag = /^[A-Z]{1,3}\d{2,}$|^\d{5,}$/i.test(withoutOrdinal[0])
    const assetTag = looksLikeTag ? withoutOrdinal[0] : null
    const rest = looksLikeTag ? withoutOrdinal.slice(1) : withoutOrdinal
    if (rest.length === 0) continue

    items.push({
      typeKey,
      heading,
      assetTag,
      model: rest[0],
      holderText: rest.length > 1 ? rest[1] : null,
    })
  }
  return items
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `cd server && npx vitest run src/popisImport.test.ts`

Expected: PASS, 19 tests.

If the "no code column" test fails because `0000001` was not recognised as a tag, check the `looksLikeTag` pattern covers 5-or-more digits — Liquiditas pads its barcodes to seven.

- [ ] **Step 5: Commit**

```bash
git add shared/popisImport.ts server/src/popisImport.test.ts
git commit -m "feat: read the equipment sheets into items, tolerating three different column layouts"
```

---

### Task 5: The import script, first pass — read and report, change nothing

**Files:**
- Create: `server/scripts/import-popis-xlsx.ts`

**Interfaces:**
- Consumes: `assetTypeForHeading`, `resolveHolder`, `parseSheet`, `ParsedItem`, `Holder` (Tasks 2–4).
- Produces: a review file at the path given by `--out`, default `popis-import-review.json`.

The script reads the `.xlsx` directly: an `.xlsx` is a ZIP of XML, and the two parts needed are `xl/sharedStrings.xml` and `xl/worksheets/sheetN.xml`. No new dependency is added — Node's `zlib` inflates the entries.

- [ ] **Step 1: Write the script**

Create `server/scripts/import-popis-xlsx.ts`:

```js
#!/usr/bin/env npx tsx
/**
 * Import the holding's equipment spreadsheet into the asset register.
 *
 * Two passes, on purpose. The first reads the workbook and writes a review
 * file saying how every row was understood, and changes nothing. A person
 * then corrects that file — above all the holders the resolver refused to
 * guess — and the second pass applies it.
 *
 * Usage:
 *   npx tsx server/scripts/import-popis-xlsx.ts read  <file.xlsx> [--out review.json]
 *   npx tsx server/scripts/import-popis-xlsx.ts apply <review.json> [--commit]
 *
 * `apply` is a dry run that prints what it would write unless --commit is
 * given. It writes to whatever SUPABASE_URL names, which is production.
 */
import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'
import { createClient } from '@supabase/supabase-js'
import { parseSheet, resolveHolder } from '../../shared/popisImport.ts'

// ----------------------------------------------------------------- xlsx

/** Entries of a ZIP, by name. An .xlsx is a ZIP of XML parts. */
function readZip(buf) {
  const files = {}
  // Walk the central directory from the end-of-central-directory record.
  let eocd = buf.length - 22
  while (eocd >= 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--
  if (eocd < 0) throw new Error('Not a zip file (no end-of-central-directory record)')
  const count = buf.readUInt16LE(eocd + 10)
  let p = buf.readUInt32LE(eocd + 16)
  for (let i = 0; i < count; i++) {
    const nameLen = buf.readUInt16LE(p + 28)
    const extraLen = buf.readUInt16LE(p + 30)
    const commentLen = buf.readUInt16LE(p + 32)
    const localOffset = buf.readUInt32LE(p + 42)
    const name = buf.toString('utf8', p + 46, p + 46 + nameLen)
    const method = buf.readUInt16LE(localOffset + 8)
    const compressed = buf.readUInt32LE(localOffset + 18)
    const lNameLen = buf.readUInt16LE(localOffset + 26)
    const lExtraLen = buf.readUInt16LE(localOffset + 28)
    const start = localOffset + 30 + lNameLen + lExtraLen
    const raw = buf.subarray(start, start + compressed)
    files[name] = method === 0 ? raw : zlib.inflateRawSync(raw)
    p += 46 + nameLen + extraLen + commentLen
  }
  return files
}

const unescapeXml = (s) =>
  s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
   .replace(/&apos;/g, "'").replace(/&amp;/g, '&')

function sharedStrings(files) {
  const xml = files['xl/sharedStrings.xml']?.toString('utf8')
  if (!xml) return []
  return [...xml.matchAll(/<si>(.*?)<\/si>/gs)].map((m) =>
    [...m[1].matchAll(/<t[^>]*>(.*?)<\/t>/gs)].map((t) => unescapeXml(t[1])).join(''),
  )
}

function sheetNames(files) {
  const wb = files['xl/workbook.xml'].toString('utf8')
  return [...wb.matchAll(/<sheet[^>]*name="([^"]+)"/g)].map((m) => unescapeXml(m[1]))
}

/** Rows of one sheet as arrays of cell text, column position preserved. */
function sheetRows(files, index, strings) {
  const xml = files[`xl/worksheets/sheet${index + 1}.xml`].toString('utf8')
  return [...xml.matchAll(/<row[^>]*>(.*?)<\/row>/gs)].map((rowMatch) => {
    const cells = []
    for (const c of rowMatch[1].matchAll(/<c([^>]*)>(.*?)<\/c>/gs)) {
      const ref = c[1].match(/r="([A-Z]+)\d+"/)
      const col = ref ? ref[1].split('').reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1 : cells.length
      const isShared = /t="s"/.test(c[1])
      const isInline = /t="(inlineStr|str)"/.test(c[1])
      const v = c[2].match(/<v>(.*?)<\/v>/s)
      const t = c[2].match(/<t[^>]*>(.*?)<\/t>/s)
      let text = null
      if (isShared && v) text = strings[Number(v[1])] ?? null
      else if (isInline && t) text = unescapeXml(t[1])
      else if (v) text = unescapeXml(v[1])
      while (cells.length < col) cells.push(null)
      cells[col] = text
    }
    return { cells }
  })
}

// ----------------------------------------------------------------- passes

const REPO_ROOT = path.resolve(new URL('../..', import.meta.url).pathname)

function env(key) {
  const raw = fs.readFileSync(path.join(REPO_ROOT, '.env.local'), 'utf8')
  const m = raw.match(new RegExp('^' + key + '=(.*)$', 'm'))
  return m ? m[1].trim() : ''
}

function db() {
  const url = env('SUPABASE_URL')
  const key = env('SUPABASE_SECRET_KEY')
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing from .env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function read(file, out) {
  const files = readZip(fs.readFileSync(file))
  const strings = sharedStrings(files)
  const names = sheetNames(files)

  const client = db()
  const [{ data: people }, { data: companies }] = await Promise.all([
    client.from('people').select('id, full_name'),
    client.from('companies').select('id, name'),
  ])

  const sheets = names.map((name, i) => {
    const items = parseSheet(sheetRows(files, i, strings))
    const company = companies.find(
      (c) => c.name.toLowerCase().replace(/\s+/g, '') === name.toLowerCase().replace(/\s+/g, ''),
    )
    return {
      sheet: name,
      companyId: company ? company.id : null,
      companyName: company ? company.name : null,
      items: items.map((item) => ({ ...item, holder: resolveHolder(item.holderText, people) })),
    }
  })

  fs.writeFileSync(out, JSON.stringify({ source: file, readAt: new Date().toISOString(), sheets }, null, 2))

  for (const s of sheets) {
    const unresolved = s.items.filter((i) => i.holder.kind === 'unresolved')
    process.stdout.write(
      `${s.sheet}: ${s.items.length} items → ${s.companyName ?? 'NO COMPANY MATCHED'}, ` +
      `${unresolved.length} holder(s) need a human\n`,
    )
    for (const u of unresolved) {
      process.stdout.write(`    ${u.assetTag ?? '(no tag)'} ${u.model} → "${u.holder.text}" (${u.holder.reason})\n`)
    }
  }
  process.stdout.write(`\nReview file written to ${out}. Correct it, then run "apply".\n`)
}

const [, , mode, file, ...rest] = process.argv
const flag = (name, fallback) => {
  const i = rest.indexOf(name)
  return i === -1 ? fallback : rest[i + 1]
}

if (mode === 'read') {
  if (!file) throw new Error('Usage: import-popis-xlsx.ts read <file.xlsx> [--out review.json]')
  await read(file, flag('--out', 'popis-import-review.json'))
} else {
  process.stdout.write('Usage: import-popis-xlsx.ts read <file.xlsx> [--out review.json]\n')
  process.exit(1)
}
```

- [ ] **Step 2: Run the first pass against the real workbook**

Run:
```bash
cd /Users/naum/Downloads/files
npx tsx server/scripts/import-popis-xlsx.ts read "Spisok na oprema vo site kompanii 2.xlsx" \
  --out /tmp/popis-review.json
```

Expected: three lines, one per sheet, naming the item count, the matched company, and the holders needing a human. Roughly 148 / 41 / 16 items. `Hut 4` may print `NO COMPANY MATCHED` if the app's company is named `Hut4` without the space — the sheet-to-company match ignores spaces, so it should match; if it does not, note it and fix in Step 3.

- [ ] **Step 3: Check the review file by eye**

Run:
```bash
node -e "
const r = require('/tmp/popis-review.json');
for (const s of r.sheets) {
  const k = {};
  for (const i of s.items) k[i.holder.kind] = (k[i.holder.kind] ?? 0) + 1;
  console.log(s.sheet, '→', s.companyName, JSON.stringify(k));
}"
```

Expected: every sheet maps to a company, `warehouse` is the largest bucket (about 53 across the workbook), and `unresolved` is a small number. If `unresolved` is large, the resolver or the parser is wrong — stop and investigate rather than proceeding.

- [ ] **Step 4: Commit**

```bash
git add server/scripts/import-popis-xlsx.ts
git commit -m "feat: read the equipment workbook into a review file, changing nothing"
```

---

### Task 6: The import script, second pass — apply the reviewed file

**Files:**
- Modify: `server/scripts/import-popis-xlsx.ts`

**Interfaces:**
- Consumes: the review file from Task 5.
- Produces: rows in `assets` and, for resolved people, open rows in `asset_assignments`.

- [ ] **Step 1: Write the apply pass**

In `server/scripts/import-popis-xlsx.ts`, add before the `const [, , mode, ...]` line:

```js
async function apply(reviewFile, commit) {
  const review = JSON.parse(fs.readFileSync(reviewFile, 'utf8'))
  const client = db()

  const unresolved = review.sheets.flatMap((s) => s.items.filter((i) => i.holder.kind === 'unresolved'))
  if (unresolved.length) {
    process.stdout.write(`${unresolved.length} holder(s) are still unresolved; they import unassigned with the original text kept in the note.\n`)
  }
  const noCompany = review.sheets.filter((s) => !s.companyId)
  if (noCompany.length) {
    throw new Error(`Refusing: no company matched for sheet(s) ${noCompany.map((s) => s.sheet).join(', ')}. Fix companyId in the review file.`)
  }

  let created = 0
  let assigned = 0
  for (const sheet of review.sheets) {
    for (const [index, item] of sheet.items.entries()) {
      // A sheet row without a code still needs a unique tag within its company.
      const tag = item.assetTag ?? `${sheet.sheet.replace(/\s+/g, '').toUpperCase()}-${String(index + 1).padStart(4, '0')}`
      const noteParts = []
      if (item.holder.kind === 'company') noteParts.push(`Held by ${item.holder.text}`)
      if (item.holder.kind === 'unresolved') noteParts.push(`Holder from spreadsheet: "${item.holder.text}" (${item.holder.reason})`)
      if (item.holder.kind === 'person' && item.holder.atCompany) noteParts.push(`Used at ${item.holder.atCompany}`)
      noteParts.push(`Imported from ${path.basename(review.source)} (${sheet.sheet})`)

      const row = {
        company_id: sheet.companyId,
        asset_tag: tag,
        type_key: item.typeKey,
        model: item.model,
        status: item.holder.kind === 'person' ? 'assigned' : 'available',
        note: noteParts.join(' · ').slice(0, 500),
      }
      if (!commit) {
        process.stdout.write(`would create ${sheet.sheet} ${row.asset_tag} ${row.type_key} "${row.model}" (${row.status})\n`)
        created++
        if (item.holder.kind === 'person') assigned++
        continue
      }
      const { data: asset, error } = await client.from('assets').insert(row).select('id').single()
      if (error) {
        process.stdout.write(`FAILED ${sheet.sheet} ${row.asset_tag}: ${error.message}\n`)
        continue
      }
      created++
      if (item.holder.kind === 'person') {
        const { error: aErr } = await client.from('asset_assignments').insert({
          asset_id: asset.id,
          person_id: item.holder.personId,
          issued_at: new Date().toISOString(),
        })
        if (aErr) process.stdout.write(`FAILED assignment ${row.asset_tag}: ${aErr.message}\n`)
        else assigned++
      }
    }
  }
  process.stdout.write(`\n${commit ? 'Created' : 'Would create'} ${created} assets, ${assigned} assigned to a person.\n`)
}
```

And replace the dispatch at the bottom with:

```js
if (mode === 'read') {
  if (!file) throw new Error('Usage: import-popis-xlsx.ts read <file.xlsx> [--out review.json]')
  await read(file, flag('--out', 'popis-import-review.json'))
} else if (mode === 'apply') {
  if (!file) throw new Error('Usage: import-popis-xlsx.ts apply <review.json> [--commit]')
  await apply(file, rest.includes('--commit'))
} else {
  process.stdout.write('Usage:\n  import-popis-xlsx.ts read  <file.xlsx> [--out review.json]\n  import-popis-xlsx.ts apply <review.json> [--commit]\n')
  process.exit(1)
}
```

- [ ] **Step 2: Run the dry run**

Run:
```bash
npx tsx server/scripts/import-popis-xlsx.ts apply /tmp/popis-review.json
```

Expected: a `would create …` line per item and a closing count near 205. **Nothing is written.** Read a dozen lines and check the type, model and status look right.

- [ ] **Step 3: Apply for real, one company first**

Edit `/tmp/popis-review.json` down to the Liquiditas sheet alone (16 items — the smallest, and the company with no prior count), then:

```bash
npx tsx server/scripts/import-popis-xlsx.ts apply /tmp/popis-review.json --commit
```

Expected: `Created 16 assets, N assigned to a person.`

- [ ] **Step 4: Check it in the app**

Open `/equipment`, filter to Liquiditas. Expected: 16 assets with their barcodes, models, and holders; the ones marked `magacin` show as available with nobody holding them.

- [ ] **Step 5: Apply the rest**

Re-run `read` to regenerate the full review file, delete the Liquiditas sheet from it (already imported), then `apply … --commit`.

Expected: `Created 189 assets`.

- [ ] **Step 6: Commit**

```bash
git add server/scripts/import-popis-xlsx.ts
git commit -m "feat: apply the reviewed equipment import into the asset register"
```

---

### Task 7: The register reads holding-wide

**Files:**
- Modify: `app/src/pages/EquipmentPage.vue`
- Create: `app/src/lib/assetRegister.ts`
- Create: `app/src/lib/assetRegister.test.ts`

**Interfaces:**
- Consumes: `assetStatusLabel` from `app/src/lib/equipment.ts`.
- Produces: `export function assetLine(asset: RegisterAsset, lookups: RegisterLookups): string`

- [ ] **Step 1: Write the failing test**

Create `app/src/lib/assetRegister.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { assetLine } from './assetRegister'

const LOOKUPS = {
  types: { laptop: 'Laptop', vehicle: 'Vehicles' },
  companies: { c1: 'Synami' },
  holders: { p1: 'Keith Attard' },
}

describe('assetLine', () => {
  it('names the category, the owning company and who holds it', () => {
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: 'p1', model: 'Dell Vostro 3500' },
      LOOKUPS,
    )).toBe('Laptop · Synami · Dell Vostro 3500 · Keith Attard')
  })

  it('says magacin when nobody holds it, rather than leaving a gap', () => {
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: null, model: 'HP ProBook' },
      LOOKUPS,
    )).toBe('Laptop · Synami · HP ProBook · magacin')
  })

  it('names the holding pool for an asset no company owns', () => {
    expect(assetLine(
      { type_key: 'vehicle', company_id: null, holder_id: null, model: 'Van' },
      LOOKUPS,
    )).toBe('Vehicles · Holding pool · Van · magacin')
  })

  it('falls back to the key for a type it does not know', () => {
    expect(assetLine(
      { type_key: 'drone', company_id: 'c1', holder_id: null, model: 'DJI' },
      LOOKUPS,
    )).toBe('drone · Synami · DJI · magacin')
  })

  it('leaves the model out rather than printing an empty segment', () => {
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: null, model: '' },
      LOOKUPS,
    )).toBe('Laptop · Synami · magacin')
  })
})
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd app && npx vitest run src/lib/assetRegister.test.ts`

Expected: FAIL — cannot resolve `./assetRegister`.

- [ ] **Step 3: Write the implementation**

Create `app/src/lib/assetRegister.ts`:

```ts
/**
 * One line describing an asset in the holding-wide register.
 *
 * The register is read across companies, so a row has to say which company
 * owns a thing and who has it without the reader consulting a filter. An
 * asset nobody holds says "magacin" — the warehouse — because a blank reads
 * as missing information rather than as a fact.
 */
export type RegisterAsset = {
  readonly type_key: string
  readonly company_id: string | null
  readonly holder_id: string | null
  readonly model: string | null
}

export type RegisterLookups = {
  readonly types: Readonly<Record<string, string>>
  readonly companies: Readonly<Record<string, string>>
  readonly holders: Readonly<Record<string, string>>
}

export const WAREHOUSE = 'magacin'

export function assetLine(asset: RegisterAsset, lookups: RegisterLookups): string {
  const type = lookups.types[asset.type_key] ?? asset.type_key
  const company = asset.company_id ? (lookups.companies[asset.company_id] ?? '—') : 'Holding pool'
  const holder = asset.holder_id ? (lookups.holders[asset.holder_id] ?? '—') : WAREHOUSE
  const model = (asset.model ?? '').trim()
  return [type, company, model, holder].filter((part) => part !== '').join(' · ')
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `cd app && npx vitest run src/lib/assetRegister.test.ts`

Expected: PASS, 5 tests.

- [ ] **Step 5: Use it on the Equipment page**

In `app/src/pages/EquipmentPage.vue`, import `assetLine` from `@/lib/assetRegister`, build a `types` lookup from the `asset_types` the page already loads (add the query if absent: `supabase.from('asset_types').select('key, label')`), and render `assetLine(...)` as the sub-line under each asset's tag. Keep the existing company filter; it now narrows a list that defaults to everything.

- [ ] **Step 6: Check the whole suite and the types**

Run:
```bash
cd app && npm run typecheck && npx vitest run
```

Expected: typecheck silent, every test passing.

- [ ] **Step 7: See it in the app**

Run `npm run dev -- --port 5233 --strictPort`, open `/equipment`, and confirm the list shows every imported asset across all companies with its category and holder, and that the company filter still narrows it.

- [ ] **Step 8: Commit**

```bash
git add app/src/lib/assetRegister.ts app/src/lib/assetRegister.test.ts app/src/pages/EquipmentPage.vue
git commit -m "feat: the equipment register reads holding-wide, with category, owner and holder on every line"
```

---

## What this slice does not do

Deliberately left for the next two plans, so this one stays shippable:

- **Slice 2 — the count.** `popis_rounds`, `popis_members`, `popis_lines`, the counting page, closing, and the report PDF.
- **Slice 3 — transfers.** `asset_transfers`, `transfer_asset` with the tag-collision refusal, and the transfer document.

## Self-review notes

Checked against the spec:

- *The register moves into the app* — Tasks 1–6. ✓
- *Two new asset types* — Task 1. ✓
- *Category mapping table* — Task 2, every row of the spec's table has an assertion. ✓
- *Holder resolution rules 1–5* — Task 3, including both refusal cases. ✓
- *Sheet quirks (column order, header row, the `√`, Liquiditas' shape)* — Task 4. ✓
- *Two-pass import with a human in the middle* — Tasks 5 and 6; `apply` is a dry run without `--commit`. ✓
- *Holding-wide view* — Task 7. ✓
- *`legal_name`* — column added in Task 1; used by the report in slice 2. ✓

One thing the spec asks for that this slice cannot honour yet: it says the import should preserve "`Name (Hut4)`" as evidence of the holding pool in use. Task 6 keeps it in `assets.note` rather than modelling it, because the pool is expressed by `company_id is null` and these assets do have an owning company. Modelling "owned by Synami, used at Hut 4" properly is a transfer-shaped question, and belongs to slice 3.
