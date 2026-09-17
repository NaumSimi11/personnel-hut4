import { describe, expect, it } from 'vitest'
import { assetTypeForHeading } from '../../shared/popisImport.js'

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
