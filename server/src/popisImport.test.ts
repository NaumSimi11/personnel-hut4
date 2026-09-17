import { describe, expect, it } from 'vitest'
import { assetTypeForHeading, parseSheet, resolveHolder } from '../../shared/popisImport.js'

describe('assetTypeForHeading', () => {
  it('maps the Macedonian headings the workbook uses', () => {
    expect(assetTypeForHeading('Лаптопи')).toBe('laptop')
    expect(assetTypeForHeading('Монитори')).toBe('monitor')
    expect(assetTypeForHeading('Desktop PC')).toBe('desktop')
    expect(assetTypeForHeading('Софтвери')).toBe('software_license')
    expect(assetTypeForHeading('Мобилни телефони')).toBe('phone')
    expect(assetTypeForHeading('Возила')).toBe('vehicle')
  })

  it('maps the English headings, because Liquiditas writes them that way', () => {
    expect(assetTypeForHeading('Laptops')).toBe('laptop')
    expect(assetTypeForHeading('Monitors')).toBe('monitor')
  })

  it('treats both spellings of the catch-all as accessories', () => {
    // Synami writes "Останати", Hut 4 writes "Останато".
    expect(assetTypeForHeading('Останати')).toBe('accessory')
    expect(assetTypeForHeading('Останато')).toBe('accessory')
  })

  it('ignores surrounding whitespace and case', () => {
    expect(assetTypeForHeading('  лаптопи  ')).toBe('laptop')
    expect(assetTypeForHeading('LAPTOPS')).toBe('laptop')
  })

  it('returns null for anything that is not a category', () => {
    expect(assetTypeForHeading('Скопје, 31.12.2025')).toBeNull()
    expect(assetTypeForHeading('1. Мите Марков')).toBeNull()
    expect(assetTypeForHeading('')).toBeNull()
  })
})

const PEOPLE = [
  { id: 'p1', full_name: 'Kristina Cvetanov' },
  { id: 'p2', full_name: 'Marko Ivanoski' },
  { id: 'p3', full_name: 'Keith Attard' },
  { id: 'p4', full_name: 'Igor Lestar' },
  { id: 'p5', full_name: 'Igor Dimkovski' },
  { id: 'dup', full_name: 'Ivan Ivanov' },
  { id: 'dup2', full_name: 'Ivan Ivanov' },
]

describe('resolveHolder', () => {
  it('reads magacin as the warehouse, however it is capitalised', () => {
    expect(resolveHolder('magacin', PEOPLE)).toEqual({ kind: 'warehouse' })
    expect(resolveHolder('Magacin', PEOPLE)).toEqual({ kind: 'warehouse' })
    expect(resolveHolder('  MAGACIN ', PEOPLE)).toEqual({ kind: 'warehouse' })
  })

  it('reads an empty cell as the warehouse', () => {
    expect(resolveHolder('', PEOPLE)).toEqual({ kind: 'warehouse' })
    expect(resolveHolder(null, PEOPLE)).toEqual({ kind: 'warehouse' })
    expect(resolveHolder(undefined, PEOPLE)).toEqual({ kind: 'warehouse' })
  })

  it('recognises a company holding its own asset', () => {
    expect(resolveHolder('Synami DOOEL', PEOPLE)).toEqual({ kind: 'company', text: 'Synami DOOEL' })
    expect(resolveHolder('Liquiditas DOOEL', PEOPLE)).toEqual({ kind: 'company', text: 'Liquiditas DOOEL' })
  })

  it('matches a person by name, ignoring case', () => {
    expect(resolveHolder('Keith Attard', PEOPLE)).toEqual({ kind: 'person', personId: 'p3', atCompany: null })
    expect(resolveHolder('keith attard', PEOPLE)).toEqual({ kind: 'person', personId: 'p3', atCompany: null })
  })

  it('keeps the company noted in brackets, which is the holding pool in use', () => {
    expect(resolveHolder('Marko Ivanoski (Hut4)', PEOPLE)).toEqual({
      kind: 'person', personId: 'p2', atCompany: 'Hut4',
    })
    expect(resolveHolder('Kristina Cvetanov (Kaj IL)', PEOPLE)).toEqual({
      kind: 'person', personId: 'p1', atCompany: 'Kaj IL',
    })
  })

  it('refuses to guess at initials', () => {
    // "IL" is probably Igor Lestar. Probably is not good enough for a name
    // that reaches a signed document.
    expect(resolveHolder('IL', PEOPLE)).toEqual({ kind: 'unresolved', text: 'IL', reason: 'no match' })
  })

  it('refuses a name that matches nobody', () => {
    expect(resolveHolder('Someone Not Here', PEOPLE)).toEqual({
      kind: 'unresolved', text: 'Someone Not Here', reason: 'no match',
    })
  })

  it('refuses a name that matches two people rather than picking one', () => {
    expect(resolveHolder('Ivan Ivanov', PEOPLE)).toEqual({
      kind: 'unresolved', text: 'Ivan Ivanov', reason: 'ambiguous',
    })
  })
})

const row = (...cells: (string | null)[]) => ({ cells })

describe('parseSheet', () => {
  it('attributes each item to the heading above it', () => {
    const items = parseSheet([
      row('Лаптопи'),
      row('ред. бр.', 'Шифра', 'Основно средство', 'Корисник', 'Забелешка'),
      row('1', 'A001', 'Dell Latitude 5590', 'magacin', '√'),
      row('Монитори'),
      row('1', 'M010', 'Monitor Dell S2721HS', 'Keith Attard', '√'),
    ])
    expect(items).toHaveLength(2)
    expect(items[0]).toMatchObject({ typeKey: 'laptop', assetTag: 'A001', model: 'Dell Latitude 5590', holderText: 'magacin' })
    expect(items[1]).toMatchObject({ typeKey: 'monitor', assetTag: 'M010', model: 'Monitor Dell S2721HS', holderText: 'Keith Attard' })
  })

  it('skips the header row rather than importing it as an asset', () => {
    // "Основно средство" is a column title; it appeared as a holder in a
    // naive first pass over this workbook.
    const items = parseSheet([
      row('Лаптопи'),
      row('Шифра', 'Основно средство', 'Забелешка', 'Корисник'),
      row('1', 'Laptop Dell XPs 13 9310', '√', 'Kristina Cvetanov'),
    ])
    expect(items).toHaveLength(1)
    expect(items[0].model).toBe('Laptop Dell XPs 13 9310')
  })

  it('ignores the tick, which records the last count and not the asset', () => {
    const items = parseSheet([
      row('Лаптопи'),
      row('Шифра', 'Основно средство', 'Корисник', 'Забелешка'),
      row('1', 'A001', 'HP ProBook', 'magacin', '√'),
    ])
    expect(JSON.stringify(items[0])).not.toContain('√')
  })

  it('ignores the closing blocks after the list', () => {
    const items = parseSheet([
      row('Лаптопи'),
      row('Шифра', 'Основно средство', 'Корисник'),
      row('1', 'A001', 'HP ProBook', 'magacin'),
      row('Пописна комисија за основни средства', 'Потпис:'),
      row('1. Мите Марков'),
      row('Скопје, 31.12.2024'),
    ])
    expect(items).toHaveLength(1)
  })

  it('reads a sheet with no code column, leaving the tag empty', () => {
    const items = parseSheet([
      row('Laptops'),
      row('Barcode', 'Model', 'User'),
      row('0000001', 'Berin Trade Mark', 'Liquiditas DOOEL'),
    ])
    expect(items[0]).toMatchObject({ assetTag: '0000001', model: 'Berin Trade Mark', holderText: 'Liquiditas DOOEL' })
  })

  it('returns nothing for a sheet with no categories at all', () => {
    expect(parseSheet([row('Some notes'), row('a', 'b')])).toEqual([])
  })
})
