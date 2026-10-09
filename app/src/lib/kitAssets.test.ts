import { describe, expect, it } from 'vitest'
import { assetLabel, assetSuggestions, hasMatchingStock, issuedLabel, kitPickerHint, type KitAssetOption } from './kitAssets'

const opt = (id: string, tag: string, type_key: string, type_label: string, extra: Partial<KitAssetOption> = {}): KitAssetOption => ({
  id,
  asset_tag: tag,
  model: null,
  serial_number: null,
  type_key,
  type_label,
  company_id: 'syn',
  company_name: 'Synami',
  ...extra,
})

const options: KitAssetOption[] = [
  opt('m1', 'MON-01', 'monitor', 'Monitor', { model: 'Dell P2422H' }),
  opt('l1', 'LT-01', 'laptop', 'Laptop', { model: 'ThinkPad T14', company_name: 'Hut4' }),
  opt('a1', 'ACC-01', 'accessory', 'Accessory', { model: 'Logitech MX Keys' }),
  opt('l2', 'LT-02', 'laptop', 'Laptop', { model: 'MacBook Air', serial_number: 'C02XYZ' }),
  opt('s1', 'SW-01', 'software_license', 'Software license', { model: 'Microsoft 365' }),
  opt('p1', 'PH-01', 'phone', 'Phone', { company_id: null, company_name: null }),
]
const ids = (item: string, q = '', limit?: number) => assetSuggestions(options, item, q, limit).map((o) => o.id)

describe('assetSuggestions', () => {
  it('puts the kind of thing the line asks for first, before anything else free', () => {
    expect(ids('Laptop').slice(0, 2)).toEqual(['l1', 'l2'])
    expect(ids('Keyboard & mouse')[0]).toBe('a1')
    expect(ids('Software licences')[0]).toBe('s1')
    expect(ids('Monitor')[0]).toBe('m1')
  })

  it('still offers everything free for a line no type matches', () => {
    expect(ids('Desk & chair')).toHaveLength(options.length)
  })

  it('narrows by tag, model, serial, type or owner as you type', () => {
    expect(ids('Laptop', 'macbook')).toEqual(['l2'])
    expect(ids('Laptop', 'c02x')).toEqual(['l2'])
    expect(ids('Laptop', 'hut4')).toEqual(['l1'])
    expect(ids('Monitor', 'lt-0')).toEqual(['l1', 'l2'])
  })

  it('stops at the limit', () => {
    expect(ids('Laptop', '', 3)).toHaveLength(3)
  })
})

describe('assetLabel', () => {
  it('reads tag, model, type and owner', () => {
    expect(assetLabel(options[1])).toBe('LT-01 · ThinkPad T14 · Laptop · Hut4')
  })

  it('calls an owner-less asset the shared pool, and skips what is missing', () => {
    expect(assetLabel(options[5])).toBe('PH-01 · Phone · Shared pool')
  })
})

describe('kitPickerHint', () => {
  it('counts the matching free stock', () => {
    expect(kitPickerHint('Laptop', options)).toBe('2 free laptops in the holding.')
    expect(kitPickerHint('Phone', options)).toBe('1 free phone in the holding.')
  })

  it('says so when nothing of that kind is free', () => {
    expect(kitPickerHint('Desk & chair', options)).toBe('Nothing of this kind is free. Pick any free asset, or tick it without one.')
    expect(kitPickerHint('Laptop', [])).toBe('No free equipment in the holding. Tick it without an asset.')
  })
})

describe('the new kinds', () => {
  const more = [...options, opt('b1', 'BDG-01', 'badge', 'Badge'), opt('f1', 'FUR-01', 'furniture', 'Furniture', { model: 'Desk 160' })]

  it('matches a badge line and a desk line to their types', () => {
    expect(assetSuggestions(more, 'Badge / access card', '')[0]?.id).toBe('b1')
    expect(assetSuggestions(more, 'Desk & chair', '')[0]?.id).toBe('f1')
    expect(kitPickerHint('Desk & chair', more)).toBe('1 free furniture in the holding.')
  })

  it('knows a vehicle by its real key', () => {
    expect(assetSuggestions([...options, opt('v1', 'CAR-01', 'vehicle', 'Vehicles')], 'Company car', '')[0]?.id).toBe('v1')
  })
})

describe('hasMatchingStock', () => {
  it('is true only when something of the line\'s kind is free', () => {
    expect(hasMatchingStock('Laptop', options)).toBe(true)
    expect(hasMatchingStock('Desk & chair', options)).toBe(false)
    expect(hasMatchingStock('Laptop', [])).toBe(false)
  })
})

describe('issuedLabel', () => {
  it('names what went out', () => {
    expect(issuedLabel({ asset_id: 'x', asset: { asset_tag: 'LT-0012', model: 'ThinkPad T14', type_label: 'Laptop', company_name: 'Synami' } })).toBe(
      'LT-0012 · ThinkPad T14 · Laptop · Synami',
    )
  })

  it('falls back for a line issued before lines kept their asset, and is empty without one', () => {
    expect(issuedLabel({ asset_id: 'x', asset: null })).toBe('a registered asset')
    expect(issuedLabel({ asset_id: null, asset: null })).toBeNull()
  })
})
