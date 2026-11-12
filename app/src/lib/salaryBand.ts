/**
 * The salary band on a hiring request (0104): what an offer is checked
 * against. Optional; both ends optional, but a band needs a currency and at
 * least one end. Stored in hiring_requests.budget as { min, max, currency }.
 */
export type SalaryBand = { min: number | null; max: number | null; currency: string }
export type BandResult = { band: SalaryBand | null; error: string | null }

const MAX = 100_000_000

function amount(raw: string): number | null | 'bad' {
  const t = raw.trim().replace(/[\s,]/g, '')
  if (!t) return null
  const n = Number(t)
  return Number.isFinite(n) && n >= 0 && n <= MAX ? Math.round(n * 100) / 100 : 'bad'
}

export function parseSalaryBand(minRaw: string, maxRaw: string, currencyRaw: string): BandResult {
  const min = amount(minRaw)
  const max = amount(maxRaw)
  const currency = currencyRaw.trim().toUpperCase()
  if (min === 'bad' || max === 'bad') return { band: null, error: 'Enter the salary band as plain amounts.' }
  if (min === null && max === null) return { band: null, error: null }
  if (!/^[A-Z]{3}$/.test(currency)) return { band: null, error: 'Give the band a three-letter currency, e.g. EUR or MKD.' }
  if (min !== null && max !== null && min > max) return { band: null, error: 'The band\'s lower end is above its upper end.' }
  return { band: { min, max, currency }, error: null }
}

/** The form's strings for a stored band. */
export function bandFields(budget: unknown): { bandMin: string; bandMax: string; bandCurrency: string } {
  const b = (budget && typeof budget === 'object' ? budget : {}) as Partial<Record<'min' | 'max' | 'currency', unknown>>
  const str = (v: unknown) => (typeof v === 'number' || typeof v === 'string' ? String(v) : '')
  return { bandMin: str(b.min), bandMax: str(b.max), bandCurrency: typeof b.currency === 'string' ? b.currency : 'EUR' }
}
