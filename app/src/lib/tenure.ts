/**
 * How long someone has been (or was) with a company, in the words a person
 * would use: "8 months", "2 years 1 month", "2 weeks", "starts in 17 days".
 * Dates are ISO strings compared in UTC, the same "today" the database uses.
 */
const DAY_MS = 86_400_000

function parse(iso: string): Date {
  return new Date(`${iso}T00:00:00Z`)
}

function monthsBetween(from: Date, to: Date): number {
  const months = (to.getUTCFullYear() - from.getUTCFullYear()) * 12 + (to.getUTCMonth() - from.getUTCMonth())
  return to.getUTCDate() < from.getUTCDate() ? months - 1 : months
}

const plural = (n: number, unit: string) => `${n} ${unit}${n === 1 ? '' : 's'}`

export function tenureLabel(start: string, end: string | null, today: string): string {
  const from = parse(start)
  if (start > today) {
    const days = Math.round((from.getTime() - parse(today).getTime()) / DAY_MS)
    return `starts in ${plural(days, 'day')}`
  }
  const to = parse(end && end < today ? end : today)
  const days = Math.round((to.getTime() - from.getTime()) / DAY_MS)
  if (days === 0) return 'today'
  if (days < 7) return plural(days, 'day')
  const months = monthsBetween(from, to)
  if (months < 1) return plural(Math.max(1, Math.round(days / 7)), 'week')
  const years = Math.floor(months / 12)
  const rest = months % 12
  if (years === 0) return plural(months, 'month')
  return rest === 0 ? plural(years, 'year') : `${plural(years, 'year')} ${plural(rest, 'month')}`
}
