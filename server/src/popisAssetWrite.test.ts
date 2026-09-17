import { describe, expect, it } from 'vitest'
import type { AssetStore, NewAssetRow, WriteResult } from './popisAssetWrite.js'
import { summarizeWrites, writeAsset, writeSheets } from './popisAssetWrite.js'

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

/** An assignment as the fake store holds it; `returnedAt` set means the asset came back. */
type FakeAssignment = { readonly personId: string; readonly returnedAt: string | null }

/**
 * A store whose asset insert always hits the duplicate key, so every call
 * takes the reconcile path. It reports an open assignment the same way the
 * real store does — only a row with no `returnedAt` counts as open.
 */
function reconcilingStore(existing: readonly FakeAssignment[], calls: string[]): AssetStore {
  return {
    ...unreachable,
    insertAsset: async () => ({
      id: null,
      error: { code: '23505', message: 'duplicate key value violates unique constraint' },
    }),
    findAssetByTag: async () => {
      const open = existing.find((assignment) => assignment.returnedAt === null)
      return { id: 'existing-asset', openAssignment: open ? { personId: open.personId } : null }
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

  it('does not write a second assignment when the reconciled asset is already issued to the same person', async () => {
    const calls: string[] = []
    const store = reconcilingStore([{ personId: 'person-1', returnedAt: null }], calls)

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(calls).toEqual(['markAssigned:existing-asset']) // no second insertAssignment
    expect(result).toEqual({ outcome: 'reconciled', assigned: true })
  })

  it('fails, naming both people, when the reconciled asset is open to someone else', async () => {
    const calls: string[] = []
    const store = reconcilingStore([{ personId: 'person-2', returnedAt: null }], calls)

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(calls).toEqual([]) // nothing written at all
    expect(result.outcome).toBe('failed')
    const message = 'message' in result ? result.message : ''
    expect(message).toContain('person-2')
    expect(message).toContain('person-1')
  })

  it('writes the assignment as before when the reconciled asset has none', async () => {
    const calls: string[] = []
    const store = reconcilingStore([], calls)

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(calls).toEqual(['insertAssignment:existing-asset:person-1', 'markAssigned:existing-asset'])
    expect(result).toEqual({ outcome: 'reconciled', assigned: true })
  })

  it('treats a returned assignment as closed, so the asset can be issued again', async () => {
    const calls: string[] = []
    const store = reconcilingStore([{ personId: 'person-2', returnedAt: '2026-01-31T00:00:00.000Z' }], calls)

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(calls).toEqual(['insertAssignment:existing-asset:person-1', 'markAssigned:existing-asset'])
    expect(result).toEqual({ outcome: 'reconciled', assigned: true })
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

describe('writeSheets', () => {
  const item = (assetTag: string, model: string, typeKey: string) => ({
    asset: { ...SAMPLE_ASSET, asset_tag: assetTag, model, type_key: typeKey },
    personId: null,
  })

  /** A store that would happily write, so an empty call log proves the refusal came first. */
  function recordingStore(calls: string[]): AssetStore {
    return {
      insertAsset: async (row) => {
        calls.push(`insertAsset:${row.asset_tag}`)
        return { id: `asset-${row.asset_tag}`, error: null }
      },
      findAssetByTag: async () => null,
      insertAssignment: async () => ({ error: null }),
      markAssigned: async () => ({ error: null, status: 'assigned' }),
    }
  }

  it('refuses before writing anything when two items of a sheet claim the same asset tag', async () => {
    const calls: string[] = []
    const sheets = [
      {
        sheet: 'Synami',
        items: [
          item('B006', 'Desktop PC', 'desktop'),
          item('B006', 'Laptop anhoch- ( se odnesuva na 2x HDD vgradeni vo serverska oprema )', 'accessory'),
        ],
      },
    ]

    const error = await writeSheets(recordingStore(calls), sheets, () => {}).then(
      () => null,
      (thrown: Error) => thrown,
    )

    expect(error).toBeInstanceOf(Error)
    expect(error?.message).toContain('Synami')
    expect(error?.message).toContain('B006')
    expect(error?.message).toContain('Desktop PC')
    expect(error?.message).toContain('2x HDD')
    expect(calls).toEqual([]) // nothing was written
  })

  it('reports every row as it lands, in sheet order, so a run that dies leaves a record', async () => {
    const calls: string[] = []
    const rows: string[] = []
    const sheets = [
      { sheet: 'Synami', items: [item('A001', 'Dell', 'laptop')] },
      { sheet: 'Hut4', items: [item('A002', 'HP', 'laptop')] },
    ]

    const results = await writeSheets(recordingStore(calls), sheets, (row) =>
      rows.push(`${row.sheet}:${row.tag}:${row.result.outcome}`),
    )

    expect(rows).toEqual(['Synami:A001:created', 'Hut4:A002:created'])
    expect(results).toEqual([
      { outcome: 'created', assigned: false },
      { outcome: 'created', assigned: false },
    ])
  })
})

describe('writeAsset status read-back', () => {
  it('fails the row when markAssigned reports success but the status does not read back as assigned', async () => {
    const store: AssetStore = {
      ...unreachable,
      insertAsset: async () => ({ id: 'asset-1', error: null }),
      insertAssignment: async () => ({ error: null }),
      markAssigned: async () => ({ error: null, status: 'available' }),
    }

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(result.outcome).toBe('failed')
    const message = 'message' in result ? result.message : ''
    expect(message).toContain('did not take effect')
    expect(message).toContain('available')
    expect(message).toContain('asset_transition')
  })

  it('accepts the row when the status reads back as assigned', async () => {
    const store: AssetStore = {
      ...unreachable,
      insertAsset: async () => ({ id: 'asset-1', error: null }),
      insertAssignment: async () => ({ error: null }),
      markAssigned: async () => ({ error: null, status: 'assigned' }),
    }

    const result = await writeAsset(store, { asset: SAMPLE_ASSET, personId: 'person-1' })

    expect(result).toEqual({ outcome: 'created', assigned: true })
  })
})
