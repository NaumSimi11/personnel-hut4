/**
 * Suggesting the next number when a new asset is registered.
 *
 * Both numbers on the label are series a company has been keeping by hand for
 * years — Synami runs A001… for laptops and B001… for desktops, Liquiditas pads
 * its barcodes to seven digits, and the accounting inventory numbers climb
 * independently of either. Whoever adds an asset should not have to open the
 * spreadsheet to find where the series got to.
 *
 * These only suggest. Nothing here reserves a number or enforces a sequence:
 * the label on the box is the authority, and a person who knows better must be
 * able to overrule the suggestion.
 */

const NUMBERED = /^([A-Za-z]*)(\d+)$/

type Series = { readonly prefix: string; readonly width: number; readonly highest: number; readonly seen: number }

/** The next tag in whichever series the company uses most, or null if there is none. */
export function nextAssetTag(existing: readonly string[]): string | null {
  const series = new Map<string, Series>()

  for (const tag of existing) {
    const parts = NUMBERED.exec(tag.trim())
    if (!parts) continue // "SPARE", or "B006-HDD" — not part of a running series
    const [, prefix, digits] = parts
    const current = series.get(prefix)
    series.set(prefix, {
      prefix,
      width: Math.max(current?.width ?? 0, digits.length),
      highest: Math.max(current?.highest ?? 0, Number(digits)),
      seen: (current?.seen ?? 0) + 1,
    })
  }
  if (series.size === 0) return null

  // The series in widest use, so a new laptop continues the laptops rather than
  // whichever prefix happens to sort last.
  const chosen = [...series.values()].reduce((best, s) => (s.seen > best.seen ? s : best))
  return `${chosen.prefix}${String(chosen.highest + 1).padStart(chosen.width, '0')}`
}

/** One past the highest inventory number recorded, or null if none has been. */
export function nextInventoryNumber(existing: readonly (string | null)[]): string | null {
  const numbers = existing
    .map((value) => (value ?? '').trim())
    .filter((value) => /^\d+$/.test(value))
    .map(Number)

  return numbers.length === 0 ? null : String(Math.max(...numbers) + 1)
}
