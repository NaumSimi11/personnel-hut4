import { zip, type ZipEntry } from './zip'

/**
 * Writing an .xlsx, with no library.
 *
 * The OOXML a spreadsheet actually needs is small: a content-type map, two
 * relationship files, a workbook naming its sheets, one worksheet per sheet
 * and a style table so dates read as dates and headers are bold. Everything
 * else Excel invents on open.
 *
 * Strings are written inline (`t="inlineStr"`) rather than through a shared
 * string table. A shared table saves bytes when the same text repeats, which
 * on a leave report means the odd leave type — not worth a second index to
 * get wrong.
 */

export type CellKind = 'text' | 'number' | 'date'

export type SheetColumn = {
  header: string
  kind?: CellKind
  /** Column width in characters; a sensible one is guessed when omitted. */
  width?: number
}

/** A date cell takes `YYYY-MM-DD`; a number cell a number; anything absent is blank. */
export type SheetCell = string | number | null | undefined

export type Sheet = {
  name: string
  columns: ReadonlyArray<SheetColumn>
  rows: ReadonlyArray<ReadonlyArray<SheetCell>>
}

const MAX_SHEET_NAME = 31
/** Excel refuses these in a sheet name, and a colon confuses some readers. */
const ILLEGAL_SHEET_CHARS = /[\\/?*[\]:]/g

export function escapeXml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
    // Excel rejects the control characters XML 1.0 forbids; a stray one in a
    // note must not cost the whole file.
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '')
}

/** A1-style reference: column 0 is A, 26 is AA. */
export function columnName(index: number): string {
  let n = index + 1
  let name = ''
  while (n > 0) {
    const rem = (n - 1) % 26
    name = String.fromCharCode(65 + rem) + name
    n = Math.floor((n - rem) / 26)
  }
  return name
}

/**
 * Excel's day number for a date.
 *
 * Day 1 is 1 January 1900 and day 60 is the 29 February that never happened,
 * so every date from 1 March 1900 is one higher than the true count. Dates
 * are read as UTC midnight, matching how the app stores them, so a timezone
 * can never move a leave day to the day before.
 */
export function dateSerial(iso: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso)
  if (!m) return null
  const ms = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
  if (Number.isNaN(ms)) return null
  return Math.floor(ms / 86_400_000) + 25569
}

function sheetName(raw: string, index: number): string {
  const cleaned = raw.replace(ILLEGAL_SHEET_CHARS, ' ').trim().slice(0, MAX_SHEET_NAME)
  return cleaned || `Sheet${index + 1}`
}

/**
 * Names, made unique.
 *
 * Two sheets with one name is a workbook Excel refuses to open, and the
 * truncation above can produce that from two names that differ only past the
 * 31st character. A repeat gets a counter, and the stem is cut to keep the
 * whole inside the limit.
 */
function uniqueSheetNames(sheets: ReadonlyArray<Sheet>): string[] {
  const taken = new Set<string>()
  return sheets.map((s, i) => {
    const base = sheetName(s.name, i)
    if (!taken.has(base.toLowerCase())) {
      taken.add(base.toLowerCase())
      return base
    }
    for (let n = 2; ; n += 1) {
      const suffix = ` (${n})`
      const candidate = base.slice(0, MAX_SHEET_NAME - suffix.length) + suffix
      if (!taken.has(candidate.toLowerCase())) {
        taken.add(candidate.toLowerCase())
        return candidate
      }
    }
  })
}

/** Wide enough for the header and the longest value, within reason. */
function guessWidth(column: SheetColumn, values: ReadonlyArray<SheetCell>): number {
  const longest = values.reduce<number>((max, v) => Math.max(max, v == null ? 0 : String(v).length), 0)
  return Math.min(60, Math.max(10, column.header.length + 2, longest + 2))
}

function cellXml(ref: string, value: SheetCell, kind: CellKind): string {
  if (value == null || value === '') return ''
  if (kind === 'number') {
    const n = typeof value === 'number' ? value : Number(value)
    if (!Number.isFinite(n)) return `<c r="${ref}" t="inlineStr"><is><t>${escapeXml(String(value))}</t></is></c>`
    return `<c r="${ref}"><v>${n}</v></c>`
  }
  if (kind === 'date') {
    const serial = dateSerial(String(value))
    // An unparseable date stays readable as the text it was, rather than
    // becoming a wrong day or an empty cell.
    if (serial === null) return `<c r="${ref}" t="inlineStr"><is><t>${escapeXml(String(value))}</t></is></c>`
    return `<c r="${ref}" s="2"><v>${serial}</v></c>`
  }
  return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${escapeXml(String(value))}</t></is></c>`
}

function worksheetXml(sheet: Sheet): string {
  const cols = sheet.columns
    .map((c, i) => {
      const width = c.width ?? guessWidth(c, sheet.rows.map((r) => r[i]))
      return `<col min="${i + 1}" max="${i + 1}" width="${width}" customWidth="1"/>`
    })
    .join('')

  const header = sheet.columns
    .map((c, i) => `<c r="${columnName(i)}1" s="1" t="inlineStr"><is><t>${escapeXml(c.header)}</t></is></c>`)
    .join('')

  const body = sheet.rows
    .map((row, r) => {
      const cells = sheet.columns
        .map((c, i) => cellXml(`${columnName(i)}${r + 2}`, row[i], c.kind ?? 'text'))
        .join('')
      return `<row r="${r + 2}">${cells}</row>`
    })
    .join('')

  const lastColumn = columnName(Math.max(0, sheet.columns.length - 1))
  const lastRow = sheet.rows.length + 1
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
<dimension ref="A1:${lastColumn}${lastRow}"/>\
<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\
<sheetFormatPr defaultRowHeight="15"/>\
<cols>${cols}</cols>\
<sheetData><row r="1">${header}</row>${body}</sheetData>\
<autoFilter ref="A1:${lastColumn}${lastRow}"/>\
</worksheet>`
}

/**
 * Three styles, referenced by index from the cells above: 0 general, 1 the
 * bold header, 2 a date. numFmtId 164 is the first id a file may define for
 * itself; the built-in date formats are locale-dependent, and a report that
 * reads 09/03 in Skopje and 03/09 in London is a report nobody can check.
 */
const STYLES_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
<numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/></numFmts>\
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
<cellXfs count="3">\
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
</cellXfs>\
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
</styleSheet>`

const RELS_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
</Relationships>`

function contentTypesXml(count: number): string {
  const sheets = Array.from(
    { length: count },
    (_, i) =>
      `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`,
  ).join('')
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
<Default Extension="xml" ContentType="application/xml"/>\
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
${sheets}\
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
</Types>`
}

function workbookXml(sheets: ReadonlyArray<Sheet>): string {
  const names = uniqueSheetNames(sheets)
  const entries = names
    .map((name, i) => `<sheet name="${escapeXml(name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`)
    .join('')
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
<sheets>${entries}</sheets></workbook>`
}

function workbookRelsXml(count: number): string {
  const sheets = Array.from(
    { length: count },
    (_, i) =>
      `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`,
  ).join('')
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
${sheets}\
<Relationship Id="rId${count + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
</Relationships>`
}

/**
 * Build the workbook. `at` stamps the archive; a fixed date makes the bytes
 * reproducible for the tests.
 */
export function buildWorkbook(sheets: ReadonlyArray<Sheet>, at: Date = new Date()): Buffer {
  if (!sheets.length) throw new Error('A workbook needs at least one sheet.')
  const utf8 = (name: string, xml: string): ZipEntry => ({ name, data: Buffer.from(xml, 'utf8') })
  return zip(
    [
      utf8('[Content_Types].xml', contentTypesXml(sheets.length)),
      utf8('_rels/.rels', RELS_XML),
      utf8('xl/workbook.xml', workbookXml(sheets)),
      utf8('xl/_rels/workbook.xml.rels', workbookRelsXml(sheets.length)),
      utf8('xl/styles.xml', STYLES_XML),
      ...sheets.map((s, i) => utf8(`xl/worksheets/sheet${i + 1}.xml`, worksheetXml(s))),
    ],
    at,
  )
}
