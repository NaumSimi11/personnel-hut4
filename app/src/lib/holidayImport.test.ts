import { describe, expect, it } from "vitest";
import { expandForImport, parseHolidayProgramme, restrictToYear, rollForwardYear } from "./holidayImport";

// Verbatim from "Програма на неработни денови за 2026 година".
const MK_2026 = `За сите граѓани на РСМ

1 јануари (четврток), Нова Година,
7 јануари (среда), Божик,  првиот ден на Божик според православниот календар,
20 март (петок), Рамазан Бајрам,  првиот ден на Рамазан Бајрам
13 април (понеделник), Велигден, вториот ден на Велигден според православниот календар,
1 мај (петок), Ден на трудот
24 мај (недела) „Св. Кирил и Методиј"- Ден на сесловенските просветители, односно 25 мај (понеделник) е неработен ден,
2 август (недела), Ден на Републиката, односно 3 август (понеделник) е неработен ден,
8 септември (вторник), Ден на независноста,
11 октомври (недела), Ден на народното востание, односно 12 октомври (понеделник) е неработен ден,
23 октомври (петок), Ден на македонската револуционерна борба,
8 декември (вторник), "Св. Климент Охридски".`;

describe("parseHolidayProgramme — official Macedonian text", () => {
  const result = parseHolidayProgramme(MK_2026, 2026);

  it("finds all eleven universal holidays and drops nothing silently", () => {
    expect(result.entries).toHaveLength(11);
    expect(result.unparsed).toEqual([]);
  });

  it("reads plain dates", () => {
    expect(result.entries[0]).toMatchObject({ date: "2026-01-01", name: "Нова Година" });
    expect(result.entries[2]).toMatchObject({ date: "2026-03-20", name: "Рамазан Бајрам" });
  });

  it("takes the quoted name when the line has one", () => {
    expect(result.entries[5].name).toBe("Св. Кирил и Методиј");
  });

  it("reads the 'односно' substitute day — the bug that cost four holidays", () => {
    expect(result.entries[5]).toMatchObject({ date: "2026-05-24", observedDate: "2026-05-25" });
    expect(result.entries[6]).toMatchObject({ date: "2026-08-02", observedDate: "2026-08-03" });
    expect(result.entries[8]).toMatchObject({ date: "2026-10-11", observedDate: "2026-10-12" });
  });

  it("ignores section headers rather than reporting them as failures", () => {
    expect(result.unparsed.some(l => l.includes("За сите"))).toBe(false);
  });

  it("flags a Sunday holiday that was given no substitute day", () => {
    const r = parseHolidayProgramme("1 ноември (недела), Празникот на сите светци", 2026);
    expect(r.entries[0].warning).toMatch(/Sunday/i);
  });
});

describe("parseHolidayProgramme — other input shapes", () => {
  it("accepts ISO lines", () => {
    const r = parseHolidayProgramme("2027-01-01, New Year's Day\n2027-05-01 Labour Day", 2027);
    expect(r.entries).toHaveLength(2);
    expect(r.entries[0]).toMatchObject({ date: "2027-01-01", name: "New Year's Day" });
  });

  it("accepts English and Serbian month names", () => {
    expect(parseHolidayProgramme("1 January, New Year", 2027).entries[0].date).toBe("2027-01-01");
    expect(parseHolidayProgramme("15 februar, Dan državnosti", 2027).entries[0].date).toBe("2027-02-15");
  });

  it("reports lines it cannot read instead of dropping them", () => {
    const r = parseHolidayProgramme("1 јануари, Нова Година\n35 notamonth, Nonsense Day", 2027);
    expect(r.entries).toHaveLength(1);
    expect(r.unparsed).toEqual(["35 notamonth, Nonsense Day"]);
  });

  it("reports a digit-free line that is not a section header — silence is how holidays go missing", () => {
    const r = parseHolidayProgramme("За сите граѓани на РСМ\nthis line is not a date at all", 2027);
    expect(r.entries).toHaveLength(0);
    expect(r.unparsed).toEqual(["this line is not a date at all"]);
  });

  it("warns when the paste contains per-faith or per-community sections", () => {
    const r = parseHolidayProgramme("За граѓаните од муслиманска вероисповед\n27 мај (среда), Курбан Бајрам", 2026);
    expect(r.entries).toHaveLength(1);
    expect(r.sectionWarnings.join(" ")).toMatch(/applies to everyone/i);
  });

  it("stays quiet when the paste has no elective sections", () => {
    expect(parseHolidayProgramme("1 јануари, Нова Година", 2027).sectionWarnings).toEqual([]);
  });

  it("rejects a date outside the target year rather than importing it into the wrong one", () => {
    const r = parseHolidayProgramme("1 јануари (петок), Нова Година", 2027);
    expect(r.entries[0].date).toBe("2027-01-01");
  });
});

describe("expandForImport", () => {
  it("emits the commemorated day AND the observed day as separate rows", () => {
    const rows = expandForImport([{ date: "2026-05-24", name: "Св. Кирил и Методиј", observedDate: "2026-05-25" }]);
    expect(rows).toEqual([
      { date: "2026-05-24", name: "Св. Кирил и Методиј", observed_of: null },
      { date: "2026-05-25", name: "Св. Кирил и Методиј (observed)", observed_of: "2026-05-24" },
    ]);
  });

  it("emits one row when there is no substitution", () => {
    expect(expandForImport([{ date: "2026-01-01", name: "Нова Година" }])).toHaveLength(1);
  });
});

describe("rollForwardYear", () => {
  const existing = [
    { date: "2026-01-01", name: "New Year's Day" },
    { date: "2026-05-01", name: "Labour Day" },
    { date: "2026-04-13", name: "Orthodox Easter Monday" },
    { date: "2026-05-25", name: "Ss. Cyril and Methodius Day (observed)" },
  ];

  it("carries fixed-date holidays into the next year", () => {
    const { entries } = rollForwardYear(existing, 2026, 2027);
    expect(entries.map(e => e.date)).toContain("2027-01-01");
    expect(entries.map(e => e.date)).toContain("2027-05-01");
  });

  it("drops the previous year's observed rows — the weekday has moved", () => {
    const { entries } = rollForwardYear(existing, 2026, 2027);
    expect(entries.some(e => e.name.includes("(observed)"))).toBe(false);
  });

  it("recomputes substitution: 1 May 2027 is a Saturday, so it needs review not a Monday", () => {
    const { entries } = rollForwardYear(existing, 2026, 2027);
    const labour = entries.find(e => e.date === "2027-05-01");
    expect(labour?.warning).toMatch(/Saturday/i);
  });

  it("sets aside movable feasts instead of carrying a wrong date", () => {
    const { needsReview } = rollForwardYear(existing, 2026, 2027);
    expect(needsReview.some(r => r.includes("Orthodox Easter Monday"))).toBe(true);
    expect(rollForwardYear(existing, 2026, 2027).entries.some(e => e.name.includes("Easter"))).toBe(false);
  });
});

describe("restrictToYear", () => {
  it("moves ISO-dated entries from another year to unparsed instead of importing them silently", () => {
    const result = parseHolidayProgramme("2026-01-01, New Year\n5 May, Something", 2027);
    const kept = restrictToYear(result, 2027);
    expect(kept.entries.map(e => e.date)).toEqual(["2027-05-05"]);
    expect(kept.unparsed).toEqual(["2026-01-01 — New Year is not in 2027"]);
  });
});

describe("cleanName with Cyrillic weekdays", () => {
  it("strips an unparenthesised weekday from the name", () => {
    const result = parseHolidayProgramme("8 септември вторник, Ден на независноста", 2026);
    expect(result.entries[0]?.name).toBe("Ден на независноста");
  });
});
