import { describe, expect, it } from 'vitest'
import { assetLine } from './assetRegister'

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
