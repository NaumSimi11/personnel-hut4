import { describe, expect, it } from 'vitest'
import { assetTypeForHeading, resolveHolder } from '../../shared/popisImport.js'

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
