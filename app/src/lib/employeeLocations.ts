import { z } from 'zod'

/**
 * Everyone working in a company has a location (25 Nov). HR fills the gaps
 * from the company's Structure tab; this orders the list and counts them.
 */
export type LocationRow = { period_id: string; full_name: string; location_id: string | null }

export function locationSummary(rows: ReadonlyArray<LocationRow>): { total: number; missing: number; line: string } {
  const missing = rows.filter((r) => !r.location_id).length
  const line = !rows.length
    ? 'Nobody is working here right now.'
    : missing
      ? `${missing} of ${rows.length} people have no location yet.`
      : 'Everyone working here has a location.'
  return { total: rows.length, missing, line }
}

/** People without a location first, then by name; the input is left as it was. */
export function missingFirst<T extends LocationRow>(rows: ReadonlyArray<T>): T[] {
  return [...rows].sort((a, b) => Number(!!a.location_id) - Number(!!b.location_id) || a.full_name.localeCompare(b.full_name))
}

export const LOCATION_HINT = 'Type where they work, e.g. Skopje, Struga or Vilnius, Lithuania.'

/** A typed place name: trimmed, single spaces, 2 to 80 characters. */
export const locationName = z
  .string()
  .transform((v) => v.trim().replace(/\s+/g, ' '))
  .pipe(z.string().min(2, LOCATION_HINT).max(80, 'Keep the location under 80 characters.'))
