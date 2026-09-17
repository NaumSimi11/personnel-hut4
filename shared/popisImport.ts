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
