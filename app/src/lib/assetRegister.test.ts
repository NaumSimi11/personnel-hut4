import { describe, expect, it } from 'vitest'
import { assetLine, assetNumbers } from './assetRegister'

const LOOKUPS = {
  types: { laptop: 'Laptop', vehicle: 'Vehicles' },
  companies: { c1: 'Synami' },
  holders: { p1: 'Keith Attard' },
}

describe('assetLine', () => {
  it('names the category, the owning company and who holds it', () => {
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: 'p1', model: 'Dell Vostro 3500' },
      LOOKUPS,
    )).toBe('Laptop · Synami · Dell Vostro 3500 · Keith Attard')
  })

  it('says magacin when nobody holds it, rather than leaving a gap', () => {
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: null, model: 'HP ProBook' },
      LOOKUPS,
    )).toBe('Laptop · Synami · HP ProBook · magacin')
  })

  it('names the holding pool for an asset no company owns', () => {
    expect(assetLine(
      { type_key: 'vehicle', company_id: null, holder_id: null, model: 'Van' },
      LOOKUPS,
    )).toBe('Vehicles · Holding pool · Van · magacin')
  })

  it('falls back to the key for a type it does not know', () => {
    expect(assetLine(
      { type_key: 'drone', company_id: 'c1', holder_id: null, model: 'DJI' },
      LOOKUPS,
    )).toBe('drone · Synami · DJI · magacin')
  })

  it('leaves the model out rather than printing an empty segment', () => {
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: null, model: '' },
      LOOKUPS,
    )).toBe('Laptop · Synami · magacin')
  })
})

describe('assetLine with what the books say', () => {
  const L = { types: { laptop: 'Laptop' }, companies: { c1: 'Synami' }, holders: { p1: 'Naum Simidjioski' } }

  it('names a real holder, as before', () => {
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: 'p1', model: 'Dell Vostro', holder_note: null },
      L,
    )).toBe('Laptop · Synami · Dell Vostro · Naum Simidjioski')
  })

  it('names who the books say holds it when no person is linked', () => {
    // This is the whole point: the register used to show "magacin" — sitting in
    // the warehouse, free to hand out — for an asset the books say someone has.
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: null, model: 'Dell Vostro', holder_note: 'Naumche Simidjioski' },
      L,
    )).toBe('Laptop · Synami · Dell Vostro · Naumche Simidjioski (from the books, not matched)')
  })

  it('still says magacin only when nothing claims it', () => {
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: null, model: 'Dell Vostro', holder_note: null },
      L,
    )).toBe('Laptop · Synami · Dell Vostro · magacin')
  })

  it('prefers the real assignment over what the books say', () => {
    expect(assetLine(
      { type_key: 'laptop', company_id: 'c1', holder_id: 'p1', model: 'Dell Vostro', holder_note: 'office' },
      L,
    )).toBe('Laptop · Synami · Dell Vostro · Naum Simidjioski')
  })
})

describe('assetNumbers', () => {
  it('shows both numbers that are printed on the label', () => {
    expect(assetNumbers({ asset_tag: 'A070', inventory_number: '121' })).toBe('A070 · инв. 121')
  })

  it('shows the tag alone when the sheet carried no inventory number', () => {
    expect(assetNumbers({ asset_tag: 'A001', inventory_number: null })).toBe('A001')
  })
})
