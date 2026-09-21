import { describe, expect, it } from 'vitest'
import {
  longDate,
  parseEducationMonth,
  parseIsoDate,
  parseUsDate,
  parseUsDateTime,
  parseSqlDateTime,
  usDateToCalendar,
  zonedToUtc,
} from './dates.js'

const TZ = 'Europe/Skopje'

describe('zonedToUtc', () => {
  it('converts a Skopje wall clock to UTC in winter (+01:00) and summer (+02:00)', () => {
    expect(zonedToUtc({ year: 2024, month: 1, day: 15, hour: 9, minute: 30, second: 0 }, TZ).toISOString())
      .toBe('2024-01-15T08:30:00.000Z')
    expect(zonedToUtc({ year: 2024, month: 7, day: 15, hour: 9, minute: 30, second: 0 }, TZ).toISOString())
      .toBe('2024-07-15T07:30:00.000Z')
  })

  it('handles the hour after the spring-forward transition', () => {
    // 31 Mar 2024 03:00 local is the first hour of CEST.
    expect(zonedToUtc({ year: 2024, month: 3, day: 31, hour: 3, minute: 0, second: 0 }, TZ).toISOString())
      .toBe('2024-03-31T01:00:00.000Z')
  })
})

describe('parseUsDateTime — MM/DD/YYYY hh:mm AM (month first)', () => {
  it('reads month first, in the export time zone', () => {
    expect(parseUsDateTime('03/12/2024 02:15 PM', TZ)).toBe('2024-03-12T13:15:00.000Z')
    expect(parseUsDateTime('12/03/2024 12:05 AM', TZ)).toBe('2024-12-02T23:05:00.000Z')
    expect(parseUsDateTime('07/04/2023 12:00 PM', TZ)).toBe('2023-07-04T10:00:00.000Z')
  })

  it('returns null for blanks and for anything that is not that shape', () => {
    expect(parseUsDateTime('', TZ)).toBeNull()
    expect(parseUsDateTime('2024-03-12 14:15:00.0', TZ)).toBeNull()
    expect(parseUsDateTime('13/12/2024 02:15 PM', TZ)).toBeNull()
    expect(parseUsDateTime('02/30/2024 02:15 PM', TZ)).toBeNull()
  })
})

describe('parseSqlDateTime — YYYY-MM-DD HH:MM:SS.0 (associations)', () => {
  it('reads the wall clock in the export time zone', () => {
    expect(parseSqlDateTime('2024-03-12 14:15:07.0', TZ)).toBe('2024-03-12T13:15:07.000Z')
    expect(parseSqlDateTime('2023-08-01 00:00:00.0', TZ)).toBe('2023-07-31T22:00:00.000Z')
  })

  it('returns null for invalid input', () => {
    expect(parseSqlDateTime('', TZ)).toBeNull()
    expect(parseSqlDateTime('03/12/2024 02:15 PM', TZ)).toBeNull()
    expect(parseSqlDateTime('2024-02-30 00:00:00.0', TZ)).toBeNull()
  })
})

describe('parseUsDate — MM/DD/YYYY (job Date Opened / Date Closed)', () => {
  it('is local midnight of that day', () => {
    expect(parseUsDate('03/12/2024', TZ)).toBe('2024-03-11T23:00:00.000Z')
    expect(parseUsDate('07/04/2023', TZ)).toBe('2023-07-03T22:00:00.000Z')
  })

  it('returns null for invalid input', () => {
    expect(parseUsDate('', TZ)).toBeNull()
    expect(parseUsDate('2024-03-12', TZ)).toBeNull()
    expect(parseUsDate('31/12/2024', TZ)).toBeNull()
  })
})

describe('usDateToCalendar', () => {
  it('keeps the calendar date, month first', () => {
    expect(usDateToCalendar('03/01/2024')).toBe('2024-03-01')
    expect(usDateToCalendar('3/1/2024')).toBe('2024-03-01')
    expect(usDateToCalendar('')).toBeNull()
    expect(usDateToCalendar('13/01/2024')).toBeNull()
  })
})

describe('parseIsoDate — YYYY-MM-DD (Hired Date)', () => {
  it('keeps the calendar date as given', () => {
    expect(parseIsoDate('2024-03-12')).toBe('2024-03-12')
  })

  it('returns null for invalid input', () => {
    expect(parseIsoDate('')).toBeNull()
    expect(parseIsoDate('2024-13-01')).toBeNull()
    expect(parseIsoDate('2024-02-30')).toBeNull()
    expect(parseIsoDate('12/03/2024')).toBeNull()
  })
})

describe('parseEducationMonth — Mon-YYYY', () => {
  it('becomes YYYY-MM', () => {
    expect(parseEducationMonth('Sep-2019')).toBe('2019-09')
    expect(parseEducationMonth('Jan-2024')).toBe('2024-01')
  })

  it('treats a year below 1900 (the Jan-1 sentinel) as no date', () => {
    expect(parseEducationMonth('Jan-1')).toBeNull()
    expect(parseEducationMonth('Jan-1899')).toBeNull()
  })

  it('returns null for blanks and other shapes', () => {
    expect(parseEducationMonth('')).toBeNull()
    expect(parseEducationMonth('2019-09')).toBeNull()
    expect(parseEducationMonth('Foo-2019')).toBeNull()
  })
})

describe('longDate', () => {
  it('prints DD Mon YYYY in the export time zone', () => {
    expect(longDate('2024-03-12T09:15:00.000Z', TZ)).toBe('12 Mar 2024')
    expect(longDate('2024-03-12T23:30:00.000Z', TZ)).toBe('13 Mar 2024')
    // zero-padded like the SQL fallback's to_char(…, 'DD Mon YYYY')
    expect(longDate('2024-03-05T09:15:00.000Z', TZ)).toBe('05 Mar 2024')
  })
})
