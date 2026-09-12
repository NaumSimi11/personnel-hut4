/**
 * Parse an official "non-working days" programme into holiday rows.
 *
 * Written against the Macedonian "Програма на неработни денови" format, which
 * is the hardest shape we need to read:
 *
 *   24 мај (недела) „Св. Кирил и Методиј"- Ден на сесловенските просветители,
 *   односно 25 мај (понеделник) е неработен ден,
 *
 * Two rules matter more than anything else here:
 *
 * 1. `односно` marks a SUBSTITUTE day. When a holiday falls on a Sunday the
 *    following Monday is the actual day off. Missing these cost four real days
 *    off in the 2026 calendar, because Sundays are already excluded as weekends
 *    and so the Sunday row had no effect at all.
 * 2. Nothing is dropped silently. Every non-header line either parses or comes
 *    back in `unparsed` for a human to look at.
 */

export type ParsedHoliday = {
  date: string;
  name: string;
  observedDate?: string;
  warning?: string;
};

export type ParseResult = { entries: ParsedHoliday[]; unparsed: string[]; sectionWarnings: string[] };

const MONTHS: Record<string, number> = {};
const register = (names: string[], month: number) => {
  for (const n of names) MONTHS[n.toLowerCase()] = month;
};
// Macedonian, Serbian (Latin + Cyrillic), English, and common abbreviations.
register(["јануари", "januar", "јануар", "january", "jan"], 1);
register(["февруари", "februar", "фебруар", "february", "feb"], 2);
register(["март", "mart", "march", "mar"], 3);
register(["април", "april", "apr"], 4);
register(["мај", "maj", "may"], 5);
register(["јуни", "jun", "јун", "june"], 6);
register(["јули", "jul", "јул", "july"], 7);
register(["август", "avgust", "august", "aug"], 8);
register(["септември", "septembar", "септембар", "september", "sep", "sept"], 9);
register(["октомври", "oktobar", "октобар", "october", "oct"], 10);
register(["ноември", "novembar", "новембар", "november", "nov"], 11);
register(["декември", "decembar", "децембар", "december", "dec"], 12);

// Weekday words are noise once the date is known; stripping them keeps names clean.
const WEEKDAYS = [
  "понеделник", "вторник", "среда", "четврток", "петок", "сабота", "недела",
  "ponedeljak", "utorak", "sreda", "četvrtak", "petak", "subota", "nedelja",
  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
];

const SUBSTITUTE_MARKERS = ["односно", "odnosno"];
const DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

const pad = (n: number) => String(n).padStart(2, "0");
const iso = (year: number, month: number, day: number) => `${year}-${pad(month)}-${pad(day)}`;

function weekdayOf(isoDate: string): string {
  return DAY_NAMES[(new Date(`${isoDate}T00:00:00.000Z`).getUTCDay() + 6) % 7];
}

function isRealDate(isoDate: string): boolean {
  const d = new Date(`${isoDate}T00:00:00.000Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === isoDate;
}

/**
 * A header like "За граѓаните од католичка вероисповед" carries no date.
 *
 * Deliberately narrow: anything else without a readable date is reported as
 * unparsed rather than skipped. Treating every digit-free line as a header is
 * how a holiday disappears without anyone noticing.
 */
function looksLikeHeader(line: string): boolean {
  if (!/\p{L}/u.test(line)) return true;                        // punctuation or numbering only
  // NOTE: \b is ASCII-only in JavaScript, so it never fires after Cyrillic "За".
  // Match on the following space or colon instead.
  if (/^(за|za|for|section|holidays)[\s:]/i.test(line)) return true;
  return /:\s*$/.test(line);
}

/** Section titles that mean "these days are not for everyone". */
const ELECTIVE_SECTION = /(вероисповед|заедница|veroispoved|zaednica|confession|community|faith)/i;

function findDate(text: string, year: number): { date: string; matched: string } | null {
  const isoMatch = /(\d{4})-(\d{2})-(\d{2})/.exec(text);
  if (isoMatch) {
    const date = `${isoMatch[1]}-${isoMatch[2]}-${isoMatch[3]}`;
    if (isRealDate(date)) return { date, matched: isoMatch[0] };
  }
  // "24 мај" / "1 January" — day then month word.
  const re = /(\d{1,2})\s*\.?\s*([\p{L}]+)/gu;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    const month = MONTHS[m[2].toLowerCase()];
    if (!month) continue;
    const day = Number(m[1]);
    const date = iso(year, month, day);
    if (isRealDate(date)) return { date, matched: m[0] };
  }
  return null;
}

function cleanName(text: string): string {
  let name = text;
  // Prefer an explicitly quoted title: „Св. Кирил и Методиј"
  const quoted = /[„“"']([^„“"']{3,})["”"']/u.exec(name);
  if (quoted) return quoted[1].trim().replace(/[-–—,.;:\s]+$/u, "");

  name = name.replace(/\([^)]*\)/g, " ");
  // \b is ASCII-only; letter lookarounds work for Cyrillic and diacritics too.
  for (const w of WEEKDAYS) name = name.replace(new RegExp(`(?<!\\p{L})${w}(?!\\p{L})`, "giu"), " ");
  // First clause after the date is the name; the rest is descriptive tail.
  const parts = name.split(/[,;]/).map(p => p.trim()).filter(Boolean);
  const first = parts.find(p => /\p{L}{3,}/u.test(p)) ?? "";
  return first.replace(/^[-–—\s"'„“]+/u, "").replace(/[-–—,.;:\s"'”"]+$/u, "").trim();
}

export function parseHolidayProgramme(text: string, year: number): ParseResult {
  const entries: ParsedHoliday[] = [];
  const unparsed: string[] = [];
  const electiveSections: string[] = [];

  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim().replace(/^[•\-*•]\s*/, "");
    if (!line) continue;
    if (looksLikeHeader(line)) {
      if (ELECTIVE_SECTION.test(line)) electiveSections.push(line);
      continue;
    }

    // Split the substitute clause off before reading the primary date.
    const markerIndex = SUBSTITUTE_MARKERS.map(m => line.toLowerCase().indexOf(m))
      .filter(i => i >= 0)
      .sort((a, b) => a - b)[0];
    const head = markerIndex === undefined ? line : line.slice(0, markerIndex);
    const tail = markerIndex === undefined ? "" : line.slice(markerIndex);

    const primary = findDate(head, year);
    if (!primary) {
      unparsed.push(line);
      continue;
    }

    const name = cleanName(head.replace(primary.matched, " "));
    if (!name) {
      unparsed.push(line);
      continue;
    }

    const entry: ParsedHoliday = { date: primary.date, name };
    const substitute = tail ? findDate(tail, year) : null;
    if (substitute && substitute.date !== primary.date) entry.observedDate = substitute.date;

    const weekday = weekdayOf(primary.date);
    if (!entry.observedDate && (weekday === "Sunday" || weekday === "Saturday")) {
      entry.warning = `Falls on a ${weekday} and no substitute day was given — confirm whether one applies.`;
    }
    entries.push(entry);
  }

  const sectionWarnings = electiveSections.length
    ? [
        `The paste contains ${electiveSections.length} per-faith or per-community section(s): ${electiveSections.join("; ")}. ` +
          "The calendar currently holds one list per country, so anything saved here applies to everyone in that country. " +
          "Import only the universal section until per-faith calendars exist.",
      ]
    : [];
  return { entries, unparsed, sectionWarnings };
}

/**
 * Flatten parsed entries into public_holidays rows (ported from Field Notebook).
 *
 * A substituted holiday becomes TWO rows: the day it commemorates, and the day
 * people are actually off. The working-day calculation only cares about the
 * second, but the first is what the calendar should label.
 */
export type HolidayRow = { date: string; name: string; observed_of: string | null };

export function expandForImport(entries: ParsedHoliday[]): HolidayRow[] {
  return entries.flatMap((entry): HolidayRow[] => {
    const own: HolidayRow = { date: entry.date, name: entry.name, observed_of: null };
    if (entry.observedDate && entry.observedDate !== entry.date) {
      return [own, { date: entry.observedDate, name: `${entry.name} (observed)`, observed_of: entry.date }];
    }
    return [own];
  });
}

// Holidays whose date is set by a lunar or paschal calendar and therefore cannot
// be carried forward by changing the year.
const MOVABLE = [
  "велигден", "easter", "великден", "бајрам", "bajram", "bayram", "ramazan", "kurban",
  "духовден", "pentecost", "велики петок", "good friday", "бадник", "богојавление",
  "yom kippur", "јом кипур", "eid",
];

/**
 * Clone one year's calendar into the next.
 *
 * Fixed-date holidays carry over with the year changed and their weekday
 * re-checked. Movable feasts are set aside for manual entry, and last year's
 * "(observed)" rows are discarded because the substitution has to be recomputed
 * against the new year's weekdays.
 */
export function rollForwardYear(
  existing: Array<{ date: string; name: string }>,
  fromYear: number,
  toYear: number
): { entries: ParsedHoliday[]; needsReview: string[] } {
  const entries: ParsedHoliday[] = [];
  const needsReview: string[] = [];

  for (const row of existing) {
    if (!row.date.startsWith(String(fromYear))) continue;
    if (/\(observed\)/i.test(row.name)) continue;

    const lower = row.name.toLowerCase();
    if (MOVABLE.some(word => lower.includes(word))) {
      needsReview.push(`${row.name} — moves each year, enter the ${toYear} date manually`);
      continue;
    }

    const date = `${toYear}${row.date.slice(4)}`;
    if (!isRealDate(date)) {
      needsReview.push(`${row.name} — ${row.date.slice(5)} does not exist in ${toYear}`);
      continue;
    }

    const entry: ParsedHoliday = { date, name: row.name };
    const weekday = weekdayOf(date);
    if (weekday === "Sunday" || weekday === "Saturday") {
      entry.warning = `Falls on a ${weekday} in ${toYear} — decide whether a substitute day applies.`;
    }
    entries.push(entry);
  }

  return { entries, needsReview };
}

/**
 * Keep only entries dated in `year`. Day-and-month lines always land in the
 * chosen year, but an ISO date carries its own; importing "2026-01-01" while
 * 2027 is selected would silently overwrite last year's row.
 */
export function restrictToYear(result: ParseResult, year: number): ParseResult {
  const prefix = `${year}-`;
  const outside = result.entries.filter(e => !e.date.startsWith(prefix));
  return {
    entries: result.entries.filter(e => e.date.startsWith(prefix)),
    unparsed: [...result.unparsed, ...outside.map(e => `${e.date} — ${e.name} is not in ${year}`)],
    sectionWarnings: result.sectionWarnings,
  };
}

export { weekdayOf };
