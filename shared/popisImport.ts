/**
 * Turning the holding's equipment spreadsheet into app concepts.
 *
 * Three sheets, three layouts, two alphabets and a decade of habit. This
 * module holds every decision about what a cell *means*; the import script
 * holds only the reading and the writing. Keeping them apart is what lets
 * the rules be tested without a workbook or a database.
 */

// Anchored at both ends: a heading is the WHOLE cell, not a cell that merely
// starts with a category word. Without the trailing `$`, an item row whose
// only populated cell happens to start with "Monitor" (e.g. a model name
// like "Monitor Dell S2721HS") would be misread as a new heading, dropping
// that item and re-filing everything after it under the wrong category.
//
// The suffix after each root is matched with `\S*`, not `\w*` — `\w` only
// covers ASCII letters/digits/underscore, and would silently fail to match
// the Cyrillic plural endings ("Лаптопи", "Монитори") these headings use.
// `\S*` still stops at the first space, which is what keeps a multi-word
// model name like "Monitor Dell S2721HS" from matching.
const HEADING_TYPES: ReadonlyArray<readonly [RegExp, string]> = [
  [/^лаптоп\S*$|^laptops?$/i, 'laptop'],
  [/^монитор\S*$|^monitors?$/i, 'monitor'],
  [/^desktop(\s+pc)?$/i, 'desktop'],
  [/^софтвер\S*$|^softwares?$/i, 'software_license'],
  [/^мобилн\S*(\s+телефон\S*)?$|^phones?$|^telefon\S*$/i, 'phone'],
  [/^возил\S*$|^vehicles?$/i, 'vehicle'],
  [/^останат[ои]$|^others?$/i, 'accessory'],
]

/** The `type_key` a category heading names, or null if it is not a category. */
export function assetTypeForHeading(heading: string): string | null {
  const text = heading.trim()
  if (!text) return null
  const hit = HEADING_TYPES.find(([pattern]) => pattern.test(text))
  return hit ? hit[1] : null
}

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
  // `\b` only treats ASCII letters/digits/underscore as word characters, so
  // it never forms a boundary around Cyrillic text — `\bДООЕЛ\b` can never
  // match anything. The Latin alternative keeps its boundaries, since those
  // correctly stop it matching inside a longer word; the Cyrillic one does
  // not need them because "ДООЕЛ" isn't a substring of any other Macedonian
  // company-form word this workbook uses.
  if (/\bDOOEL\b|ДООЕЛ/i.test(text)) return { kind: 'company', text }

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

export type SheetRow = { readonly cells: readonly (string | null)[] }

export type ParsedItem = {
  readonly typeKey: string
  readonly heading: string
  /** Шифра — the code on the label. */
  readonly assetTag: string | null
  /** Инв. бр. — the accounting inventory number, also on the label. */
  readonly inventoryNumber: string | null
  readonly model: string
  readonly holderText: string | null
  /** Anything the sheet carried that has no column of its own. */
  readonly note: string | null
}

/** What a column heading means, whichever of the three sheets wrote it. */
type Field = 'ordinal' | 'tag' | 'model' | 'holder' | 'tick' | 'inventory'

const COLUMN_FIELDS: ReadonlyArray<readonly [RegExp, Field]> = [
  [/^ред\.?\s*бр\.?$/i, 'ordinal'],
  [/^(шифра|barcode)$/i, 'tag'],
  [/^(основно средство|model)$/i, 'model'],
  [/^(корисник|user)$/i, 'holder'],
  [/^забелешка$/i, 'tick'],
  [/^инв\.?\s*бр\.?$/i, 'inventory'],
]

const ASSET_TAG = /^[A-Z]{1,3}\d{2,}$|^\d{5,}$/i
const CLOSING = /пописна\S*\s+комисија|потпис|скопје,|^\d+\.\s/i

function fieldFor(heading: string): Field | null {
  const hit = COLUMN_FIELDS.find(([pattern]) => pattern.test(heading.trim()))
  return hit ? hit[1] : null
}

/** The column map a header row describes, or null if this is not a header row. */
function readHeader(cells: readonly (string | null)[]): Map<number, Field> | null {
  const map = new Map<number, Field>()
  for (const [index, raw] of cells.entries()) {
    const text = (raw ?? '').trim()
    if (!text) continue
    const field = fieldFor(text)
    if (!field) return null // a word that is not a column title means this is data
    map.set(index, field)
  }
  return map.size >= 2 ? map : null
}

function at(cells: readonly (string | null)[], map: Map<number, Field>, want: Field): string | null {
  for (const [index, field] of map) {
    if (field !== want) continue
    const text = (cells[index] ?? '').trim()
    if (text) return text
  }
  return null
}

/**
 * The items in a sheet, read through each category's own header row.
 *
 * Reading by position was the original mistake, and it silently dropped Инв.
 * бр. — the accounting inventory number, which is printed on the same physical
 * label as the Шифра and is just as much the asset's identity. The three sheets
 * agree on nothing else either: Synami leads with a row number, Hut 4 does not;
 * Hut 4 puts Забелешка *before* Корисник and keeps its real codes (A050, A062)
 * in a column with no heading at all, beside free text; Liquiditas names its
 * columns in English and has no tick. Only the header row says which column is
 * which, so that is what this reads — and an empty cell stays empty rather than
 * sliding the rest of the row left.
 */
export function parseSheet(rows: readonly SheetRow[]): ParsedItem[] {
  const items: ParsedItem[] = []
  let heading: string | null = null
  let typeKey: string | null = null
  let columns: Map<number, Field> | null = null

  for (const raw of rows) {
    const cells = raw.cells
    const filled = cells.map((c) => (c ?? '').trim()).filter((c) => c !== '')
    if (filled.length === 0) continue

    if (filled.length === 1) {
      const found = assetTypeForHeading(filled[0])
      if (found) {
        heading = filled[0]
        typeKey = found
        columns = null // every category restates its own header
        continue
      }
    }
    if (!typeKey || !heading) continue
    if (filled.some((c) => CLOSING.test(c))) continue

    const header = readHeader(cells)
    if (header) {
      columns = header
      continue
    }
    if (!columns) continue

    const model = at(cells, columns, 'model')
    if (!model) continue

    // Hut 4 numbers its rows in the column it calls Шифра, and keeps the real
    // code in a trailing column with no heading, mixed with free text.
    const named = at(cells, columns, 'tag')
    const spare = cells
      .map((c, i) => (columns?.has(i) ? '' : (c ?? '').trim()))
      .filter((c) => c !== '')
    const spareTag = spare.find((c) => ASSET_TAG.test(c)) ?? null
    const assetTag = named && ASSET_TAG.test(named) ? named : spareTag
    const note = spare.filter((c) => c !== assetTag).join(' · ') || null

    items.push({
      typeKey,
      heading,
      assetTag,
      inventoryNumber: at(cells, columns, 'inventory'),
      model,
      holderText: at(cells, columns, 'holder'),
      note,
    })
  }
  return items
}
