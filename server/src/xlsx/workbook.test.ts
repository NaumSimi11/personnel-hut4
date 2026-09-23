import { describe, expect, it } from 'vitest'
import { inflateRawSync } from 'node:zlib'
import { buildWorkbook, columnName, dateSerial, escapeXml, type Sheet } from './workbook'
import { crc32, dosStamp, zip } from './zip'

const AT = new Date(Date.UTC(2026, 8, 23, 9, 30, 0))

/**
 * Read an entry back out of an archive the way a reader does: walk the
 * central directory from the end, not the local headers. A test that trusted
 * the local headers would pass even if the directory pointed at nonsense,
 * which is exactly the mistake that makes Excel refuse a file.
 */
function readEntry(archive: Buffer, name: string): Buffer {
  const eocd = archive.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]))
  expect(eocd).toBeGreaterThan(-1)
  const count = archive.readUInt16LE(eocd + 10)
  let at = archive.readUInt32LE(eocd + 16)
  for (let i = 0; i < count; i += 1) {
    expect(archive.readUInt32LE(at)).toBe(0x02014b50)
    const nameLen = archive.readUInt16LE(at + 28)
    const extraLen = archive.readUInt16LE(at + 30)
    const commentLen = archive.readUInt16LE(at + 32)
    const entryName = archive.subarray(at + 46, at + 46 + nameLen).toString('utf8')
    const offset = archive.readUInt32LE(at + 42)
    if (entryName === name) {
      const localNameLen = archive.readUInt16LE(offset + 26)
      const localExtraLen = archive.readUInt16LE(offset + 28)
      const size = archive.readUInt32LE(offset + 18)
      const start = offset + 30 + localNameLen + localExtraLen
      const body = inflateRawSync(archive.subarray(start, start + size))
      expect(crc32(body)).toBe(archive.readUInt32LE(at + 16))
      return body
    }
    at += 46 + nameLen + extraLen + commentLen
  }
  throw new Error(`${name} is not in the archive`)
}

const sheet: Sheet = {
  name: 'Leave',
  columns: [
    { header: 'Person' },
    { header: 'Start', kind: 'date' },
    { header: 'Working days', kind: 'number' },
    { header: 'Note' },
  ],
  rows: [
    ['Ana Kova', '2026-09-01', 5, 'Summer & sun'],
    ['Ben Ilić', '2026-09-14', 0.5, null],
    ['Cy <Dan>', 'not a date', 'nine', ''],
  ],
}

describe('zip', () => {
  it('computes the CRC-32 the format expects', () => {
    expect(crc32(Buffer.from(''))).toBe(0)
    expect(crc32(Buffer.from('123456789'))).toBe(0xcbf43926)
  })

  it('floors the DOS stamp at 1980, which is the format’s epoch', () => {
    expect(dosStamp(new Date(Date.UTC(1970, 0, 1))).date >> 9).toBe(0)
  })

  it('round-trips an entry through the central directory', () => {
    const archive = zip([{ name: 'a.txt', data: Buffer.from('hello') }], AT)
    expect(readEntry(archive, 'a.txt').toString()).toBe('hello')
  })

  it('is reproducible for a fixed stamp', () => {
    const one = zip([{ name: 'a.txt', data: Buffer.from('hello') }], AT)
    const two = zip([{ name: 'a.txt', data: Buffer.from('hello') }], AT)
    expect(one.equals(two)).toBe(true)
  })
})

describe('columnName', () => {
  it('counts in the spreadsheet’s own base', () => {
    expect(columnName(0)).toBe('A')
    expect(columnName(25)).toBe('Z')
    expect(columnName(26)).toBe('AA')
    expect(columnName(51)).toBe('AZ')
    expect(columnName(701)).toBe('ZZ')
  })
})

describe('dateSerial', () => {
  it('matches the numbers a spreadsheet stores', () => {
    // The known pair: 1 January 2000 is 36526 and 1 March 1900 is 61, which
    // only lines up if the 1900 leap-year bug is carried.
    expect(dateSerial('2000-01-01')).toBe(36526)
    expect(dateSerial('1900-03-01')).toBe(61)
    expect(dateSerial('2026-09-23')).toBe(46288)
  })

  it('reads the date out of a timestamp and refuses anything else', () => {
    expect(dateSerial('2026-09-23T22:00:00+02:00')).toBe(46288)
    expect(dateSerial('yesterday')).toBeNull()
    expect(dateSerial('')).toBeNull()
  })
})

describe('escapeXml', () => {
  it('escapes the five, and drops control characters a file cannot carry', () => {
    expect(escapeXml('a & b < c > "d" \'e\'')).toBe('a &amp; b &lt; c &gt; &quot;d&quot; &apos;e&apos;')
    expect(escapeXml('ok\u0007here')).toBe('okhere')
    expect(escapeXml('keep\ttabs\nand newlines')).toBe('keep\ttabs\nand newlines')
  })
})

describe('buildWorkbook', () => {
  const archive = buildWorkbook([sheet], AT)
  const worksheet = readEntry(archive, 'xl/worksheets/sheet1.xml').toString('utf8')

  it('refuses a workbook with no sheet', () => {
    expect(() => buildWorkbook([], AT)).toThrow(/at least one sheet/)
  })

  it('writes every part a reader looks for', () => {
    for (const part of [
      '[Content_Types].xml',
      '_rels/.rels',
      'xl/workbook.xml',
      'xl/_rels/workbook.xml.rels',
      'xl/styles.xml',
      'xl/worksheets/sheet1.xml',
    ]) {
      expect(readEntry(archive, part).length).toBeGreaterThan(0)
    }
  })

  it('names the sheet, and falls back when the name is unusable', () => {
    expect(readEntry(archive, 'xl/workbook.xml').toString()).toContain('name="Leave"')
    const odd = buildWorkbook([{ ...sheet, name: '  [*]/  ' }], AT)
    expect(readEntry(odd, 'xl/workbook.xml').toString()).toContain('name="Sheet1"')
    const long = buildWorkbook([{ ...sheet, name: 'x'.repeat(40) }], AT)
    expect(readEntry(long, 'xl/workbook.xml').toString()).toContain(`name="${'x'.repeat(31)}"`)
  })

  it('heads the sheet in bold and freezes it', () => {
    expect(worksheet).toContain('<c r="A1" s="1" t="inlineStr"><is><t>Person</t></is></c>')
    expect(worksheet).toContain('state="frozen"')
    expect(worksheet).toContain('<autoFilter ref="A1:D4"/>')
  })

  it('writes a date as a number with the date style, not as text', () => {
    expect(worksheet).toContain(`<c r="B2" s="2"><v>${dateSerial('2026-09-01')}</v></c>`)
  })

  it('writes a number as a number, including a half day', () => {
    expect(worksheet).toContain('<c r="C2"><v>5</v></c>')
    expect(worksheet).toContain('<c r="C3"><v>0.5</v></c>')
  })

  it('escapes text and keeps an empty cell out of the file entirely', () => {
    expect(worksheet).toContain('Summer &amp; sun')
    expect(worksheet).toContain('Cy &lt;Dan&gt;')
    expect(worksheet).not.toContain('r="D3"') // null note
    expect(worksheet).not.toContain('r="D4"') // empty string
  })

  it('keeps an unreadable date or number as the text it was, rather than a wrong value', () => {
    expect(worksheet).toContain('<c r="B4" t="inlineStr"><is><t>not a date</t></is></c>')
    expect(worksheet).toContain('<c r="C4" t="inlineStr"><is><t>nine</t></is></c>')
  })

  it('makes two colliding names unique, because Excel refuses a workbook with a repeat', () => {
    const twice = buildWorkbook([sheet, { ...sheet, name: 'Leave' }], AT)
    const xml = readEntry(twice, 'xl/workbook.xml').toString()
    expect(xml).toContain('name="Leave"')
    expect(xml).toContain('name="Leave (2)"')
    // Even when the clash only appears after the 31-character truncation.
    const long = 'x'.repeat(40)
    const cut = buildWorkbook([{ ...sheet, name: `${long}A` }, { ...sheet, name: `${long}B` }], AT)
    const names = [...readEntry(cut, 'xl/workbook.xml').toString().matchAll(/name="([^"]+)"/g)].map((m) => m[1])
    expect(new Set(names).size).toBe(2)
    expect(names.every((n) => n.length <= 31)).toBe(true)
  })

  it('carries several sheets, each with its own relationship', () => {
    const two = buildWorkbook([sheet, { ...sheet, name: 'Summary' }], AT)
    expect(readEntry(two, 'xl/worksheets/sheet2.xml').length).toBeGreaterThan(0)
    const rels = readEntry(two, 'xl/_rels/workbook.xml.rels').toString()
    expect(rels).toContain('Target="worksheets/sheet2.xml"')
    expect(rels).toContain('Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"')
  })
})
