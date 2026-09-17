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
