import { describe, expect, it } from 'vitest'
import type { AssetStore, NewAssetRow, WriteResult } from './popisAssetWrite.js'
import { summarizeWrites, writeAsset } from './popisAssetWrite.js'

const SAMPLE_ASSET: NewAssetRow = {
  company_id: 'company-1',
  asset_tag: 'A001',
  type_key: 'laptop',
  model: 'Dell Latitude 5590',
  note: 'Imported from workbook.xlsx (Synami)',
}

/** A store whose every method fails the test if called — for asserting a step never runs. */
const unreachable: AssetStore = {
  insertAsset: () => { throw new Error('insertAsset should not have been called') },
  findAssetByTag: () => { throw new Error('findAssetByTag should not have been called') },
  insertAssignment: () => { throw new Error('insertAssignment should not have been called') },
  markAssigned: () => { throw new Error('markAssigned should not have been called') },
}

describe('writeAsset', () => {
  it('writes available -> assignment -> assigned, in that order, for a person holder', async () => {
    const calls: string[] = []
    const store: AssetStore = {
      ...unreachable,
      insertAsset: async (row) => {
        calls.push(`insertAsset:${row.status}`)
        return { id: 'asset-1', error: null }
      },
      insertAssignment: async (assetId, personId) => {
        calls.push(`insertAssignment:${assetId}:${personId}`)
        return { error: null }
      },
      markAssigned: async (assetId) => {
        calls.push(`markAssigned:${assetId}`)
        return { error: null }
      },
    }

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(calls).toEqual(['insertAsset:available', 'insertAssignment:asset-1:person-1', 'markAssigned:asset-1'])
    expect(result).toEqual({ outcome: 'created', assigned: true })
  })

  it('leaves the asset available and never marks it assigned when the assignment insert fails', async () => {
    const calls: string[] = []
    const store: AssetStore = {
      ...unreachable,
      insertAsset: async () => ({ id: 'asset-1', error: null }),
      insertAssignment: async () => {
        calls.push('insertAssignment')
        return { error: { message: 'connection reset' } }
      },
      markAssigned: async () => {
        calls.push('markAssigned') // must not happen
        return { error: null }
      },
    }

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(calls).toEqual(['insertAssignment']) // markAssigned never reached
    expect(result).toEqual({ outcome: 'created', assigned: false, warning: 'assignment failed: connection reset' })
  })

  it('reconciles a duplicate asset_tag to the existing row and still writes the assignment', async () => {
    const store: AssetStore = {
      insertAsset: async () => ({ id: null, error: { code: '23505', message: 'duplicate key value violates unique constraint' } }),
      findAssetByTag: async (companyId, assetTag) => {
        expect(companyId).toBe(SAMPLE_ASSET.company_id)
        expect(assetTag).toBe(SAMPLE_ASSET.asset_tag)
        return { id: 'existing-asset' }
      },
      insertAssignment: async (assetId) => {
        expect(assetId).toBe('existing-asset')
        return { error: null }
      },
      markAssigned: async (assetId) => {
        expect(assetId).toBe('existing-asset')
        return { error: null }
      },
    }

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(result).toEqual({ outcome: 'reconciled', assigned: true })
  })

  it('fails outright when the asset insert errors for a reason other than a duplicate key', async () => {
    const store: AssetStore = {
      ...unreachable,
      insertAsset: async () => ({ id: null, error: { code: '23503', message: 'foreign key violation' } }),
    }

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(result).toEqual({ outcome: 'failed', message: 'foreign key violation' })
  })

  it('does not write an assignment for a non-person holder', async () => {
    const store: AssetStore = {
      ...unreachable,
      insertAsset: async () => ({ id: 'asset-1', error: null }),
    }

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: null })

    expect(result).toEqual({ outcome: 'created', assigned: false })
  })

  it('does not mutate the item or the asset row it is given', async () => {
    const asset = Object.freeze({ ...SAMPLE_ASSET })
    const item = Object.freeze({ asset, personId: 'person-1' })
    const store: AssetStore = {
      insertAsset: async () => ({ id: 'asset-1', error: null }),
      findAssetByTag: async () => null,
      insertAssignment: async () => ({ error: null }),
      markAssigned: async () => ({ error: null }),
    }

    await expect(writeAsset(store, item)).resolves.toEqual({ outcome: 'created', assigned: true })
  })
})

describe('summarizeWrites', () => {
  it('reports created, reconciled, failed and assigned separately', () => {
    const results: WriteResult[] = [
      { outcome: 'created', assigned: true },
      { outcome: 'created', assigned: false },
      { outcome: 'reconciled', assigned: true },
      { outcome: 'failed', message: 'boom' },
    ]

    expect(summarizeWrites(results)).toEqual({ created: 2, reconciled: 1, failed: 1, assigned: 2 })
  })

  it('does not mutate the results array', () => {
    const results: readonly WriteResult[] = Object.freeze([{ outcome: 'created' as const, assigned: true }])
    summarizeWrites(results)
    expect(results).toEqual([{ outcome: 'created', assigned: true }])
  })
})
