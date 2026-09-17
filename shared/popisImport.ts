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
// A cell that looks like an asset tag: letters-then-digits (A001), or a
// barcode padded to five digits or more. Liquiditas pads its barcodes to
// seven digits — "0000001" — which would also match ORDINAL above, so this
// check has to run first. Only a cell that fails it may later be stripped
// as a row number.
const ASSET_TAG = /^[A-Z]{1,3}\d{2,}$|^\d{5,}$/i

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

    // Drop the tick first; what remains starts with either an ordinal, an
    // asset tag, or the model straight away.
    const body = cells.filter((c) => !TICK.test(c))
    if (body.length === 0) continue

    // A cell is only ever stripped as an ordinal once it has been cleared
    // of being an asset tag — a zero-padded barcode matches both patterns,
    // and being a tag takes precedence.
    const firstIsTag = ASSET_TAG.test(body[0])
    const withoutOrdinal =
      !firstIsTag && body.length > 1 && ORDINAL.test(body[0]) ? body.slice(1) : body
    if (withoutOrdinal.length === 0) continue

    const looksLikeTag = ASSET_TAG.test(withoutOrdinal[0])
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
