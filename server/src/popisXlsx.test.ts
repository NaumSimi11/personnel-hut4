import { describe, expect, it } from 'vitest'
import { parseRowCells } from './popisXlsxCells.js'

describe('parseRowCells', () => {
  it('reads a shared-string cell that follows a self-closing (empty) cell', () => {
    // The exact shape that corrupted 31 real rows: B121 is empty and
    // self-closing; without the fix its `/` gets read as the start of a
    // body, swallowing C121 whole — so C121's value lands in column B, and
    // its `t="s"` attribute (the one that says "look this index up in
    // sharedStrings") is never seen because B121's attributes have no such
    // flag.
    const row =
      '<c r="A121" s="90"><v>105</v></c>' +
      '<c r="B121" s="54"/>' +
      '<c r="C121" s="54" t="s"><v>351</v></c>' +
      '<c r="D121" s="54" t="s"><v>359</v></c>'
    const strings = new Array(360).fill('')
    strings[351] = 'Seavus project viewer'
    strings[359] = 'Синами Софтвери'

    const cells = parseRowCells(row, strings)

    expect(cells[1]).toBeNull() // B121: empty, self-closing
    expect(cells[2]).toBe('Seavus project viewer') // C121: the shared string, not "351"
    expect(cells[3]).toBe('Синами Софтвери')
  })

  it('treats a self-closing cell with no siblings as an empty row', () => {
    expect(parseRowCells('<c r="A1" s="1"/>', [])).toEqual([null])
  })

  it('still reads inline strings and raw numeric values', () => {
    const row =
      '<c r="A1" t="inlineStr"><is><t>Laptop</t></is></c>' +
      '<c r="B1"><v>42</v></c>'
    expect(parseRowCells(row, [])).toEqual(['Laptop', '42'])
  })

  it('unescapes XML entities in inline and raw text', () => {
    const row = '<c r="A1" t="str"><t>Tom &amp; Jerry</t></c>'
    expect(parseRowCells(row, [])).toEqual(['Tom & Jerry'])
  })
})
