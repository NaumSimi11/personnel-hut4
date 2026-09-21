import { describe, expect, it } from 'vitest'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { EXPORT_FILES, parseCsv, readExport, splitList } from './csv.js'

const FIXTURES = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures')

describe('parseCsv', () => {
  it('reads RFC 4180: a BOM, quoted commas, doubled quotes and multi-line fields', () => {
    const text = '﻿"Note Id","Note Content",Module\n' +
      'Zrecruit_1,"line one\nline two, with a comma and a ""quote""",Candidates\n' +
      'Zrecruit_2,plain,Candidates\n'
    const rows = parseCsv(text)
    expect(rows).toHaveLength(2)
    expect(rows[0]['Note Id']).toBe('Zrecruit_1')
    expect(rows[0]['Note Content']).toBe('line one\nline two, with a comma and a "quote"')
    expect(rows[0].Module).toBe('Candidates')
    expect(rows[1]['Note Content']).toBe('plain')
  })

  it('keeps every column as a string, blanks included', () => {
    const rows = parseCsv('A,B\n1,\n')
    expect(rows[0]).toEqual({ A: '1', B: '' })
  })

  it('refuses a ragged row rather than shifting columns', () => {
    expect(() => parseCsv('A,B\n1,2,3\n')).toThrow()
  })
})

describe('splitList', () => {
  it('splits on the separator, trims and drops blanks', () => {
    expect(splitList(' a, b ,,c ')).toEqual(['a', 'b', 'c'])
    expect(splitList('')).toEqual([])
    expect(splitList('x;y', ';')).toEqual(['x', 'y'])
  })
})

describe('readExport', () => {
  it('reads every table of the synthetic export', () => {
    const exp = readExport(path.join(FIXTURES, 'Data'))
    expect(Object.keys(EXPORT_FILES).sort()).toEqual(Object.keys(exp).sort())
    expect(exp.candidates).toHaveLength(3)
    expect(exp.associations.length).toBeGreaterThan(0)
    expect(exp.jobs.length).toBeGreaterThan(0)
    expect(exp.users.length).toBeGreaterThan(0)
  })
})
