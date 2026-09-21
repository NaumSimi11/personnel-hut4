/**
 * The four date shapes of the Zoho Recruit export (plan 052 §3.1). Every
 * stamp is a wall clock in the export's time zone (Europe/Skopje); an
 * invalid value is null and the caller records a problem. Pure: no I/O.
 */

export type WallClock = { year: number; month: number; day: number; hour: number; minute: number; second: number }

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

const formatters = new Map<string, Intl.DateTimeFormat>()

function formatterFor(tz: string): Intl.DateTimeFormat {
  const cached = formatters.get(tz)
  if (cached) return cached
  const created = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
  formatters.set(tz, created)
  return created
}

/** The wall clock of an instant in a time zone. */
export function wallClockOf(instant: Date, tz: string): WallClock {
  const parts: Record<string, number> = {}
  for (const p of formatterFor(tz).formatToParts(instant)) {
    if (p.type !== 'literal') parts[p.type] = Number(p.value)
  }
  return { year: parts.year, month: parts.month, day: parts.day, hour: parts.hour % 24, minute: parts.minute, second: parts.second }
}

function asUtcMs(w: WallClock): number {
  return Date.UTC(w.year, w.month - 1, w.day, w.hour, w.minute, w.second)
}

/** Minutes east of UTC for `tz` at the given instant. */
function offsetMinutes(utcMs: number, tz: string): number {
  return (asUtcMs(wallClockOf(new Date(utcMs), tz)) - utcMs) / 60000
}

/**
 * The instant a wall clock names in `tz`. Guess UTC = the same numbers,
 * correct by the zone offset at that guess, then once more at the corrected
 * instant so the hour around a DST switch lands on the right side.
 */
export function zonedToUtc(w: WallClock, tz: string): Date {
  const guess = asUtcMs(w)
  const first = offsetMinutes(guess, tz)
  let utc = guess - first * 60000
  const second = offsetMinutes(utc, tz)
  if (second !== first) utc = guess - second * 60000
  return new Date(utc)
}

function validCalendar(year: number, month: number, day: number): boolean {
  if (month < 1 || month > 12 || day < 1 || day > 31 || year < 1) return false
  const probe = new Date(Date.UTC(year, month - 1, day))
  return probe.getUTCFullYear() === year && probe.getUTCMonth() === month - 1 && probe.getUTCDate() === day
}

function toIso(w: WallClock, tz: string): string | null {
  if (!validCalendar(w.year, w.month, w.day)) return null
  if (w.hour > 23 || w.minute > 59 || w.second > 59) return null
  return zonedToUtc(w, tz).toISOString()
}

/** `MM/DD/YYYY hh:mm AM` — month first (candidates, notes, attachments, job Created Time). */
export function parseUsDateTime(value: string, tz: string): string | null {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4}) (\d{1,2}):(\d{2}) (AM|PM)$/.exec(value.trim())
  if (!m) return null
  const hour12 = Number(m[4])
  if (hour12 < 1 || hour12 > 12) return null
  const hour = (hour12 % 12) + (m[6] === 'PM' ? 12 : 0)
  return toIso({ year: Number(m[3]), month: Number(m[1]), day: Number(m[2]), hour, minute: Number(m[5]), second: 0 }, tz)
}

/** `YYYY-MM-DD HH:MM:SS.0` — the associations. */
export function parseSqlDateTime(value: string, tz: string): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.\d+)?$/.exec(value.trim())
  if (!m) return null
  return toIso(
    { year: Number(m[1]), month: Number(m[2]), day: Number(m[3]), hour: Number(m[4]), minute: Number(m[5]), second: Number(m[6]) },
    tz,
  )
}

/** `MM/DD/YYYY` — job Date Opened / Date Closed, as local midnight. */
export function parseUsDate(value: string, tz: string): string | null {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(value.trim())
  if (!m) return null
  return toIso({ year: Number(m[3]), month: Number(m[1]), day: Number(m[2]), hour: 0, minute: 0, second: 0 }, tz)
}

/** `MM/DD/YYYY` kept as the calendar date `YYYY-MM-DD` (the job facts in custom.zoho). */
export function usDateToCalendar(value: string): string | null {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(value.trim())
  if (!m || !validCalendar(Number(m[3]), Number(m[1]), Number(m[2]))) return null
  return `${m[3]}-${m[1].padStart(2, '0')}-${m[2].padStart(2, '0')}`
}

/** `YYYY-MM-DD` — Hired Date, kept as a calendar date. */
export function parseIsoDate(value: string): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value.trim())
  if (!m) return null
  return validCalendar(Number(m[1]), Number(m[2]), Number(m[3])) ? m[0] : null
}

/** `Mon-YYYY` → `YYYY-MM`; a year below 1900 (the `Jan-1` sentinel) is no date. */
export function parseEducationMonth(value: string): string | null {
  const m = /^([A-Za-z]{3})-(\d{1,4})$/.exec(value.trim())
  if (!m) return null
  const month = MONTHS.indexOf(m[1])
  const year = Number(m[2])
  if (month < 0 || year < 1900) return null
  return `${year}-${String(month + 1).padStart(2, '0')}`
}

/** `DD Mon YYYY` in the export time zone, zero-padded like to_char(…, 'DD Mon YYYY'). */
export function longDate(iso: string, tz: string): string {
  const w = wallClockOf(new Date(iso), tz)
  return `${String(w.day).padStart(2, '0')} ${MONTHS[w.month - 1]} ${w.year}`
}
