import { describe, expect, it } from 'vitest'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabaseStore } from './popisSupabaseStore.js'

type Reply = { readonly data: unknown; readonly error: { readonly code?: string; readonly message: string } | null }

/**
 * A stand-in for the Supabase query builder: every step returns itself, and
 * awaiting it — directly or through `single`/`maybeSingle`/`limit` — yields
 * the reply queued for that table. One `from(table)` call takes one reply,
 * so a queue reads as the statements the store is expected to run.
 */
function fakeClient(queues: Record<string, Reply[]>, tables: string[] = []): SupabaseClient {
  const builder = (reply: Reply): unknown => {
    const self: Record<string, unknown> = {
      then: (resolve: (value: Reply) => unknown) => Promise.resolve(reply).then(resolve),
      single: async () => reply,
      maybeSingle: async () => reply,
    }
    for (const step of ['select', 'eq', 'is', 'limit', 'insert', 'update']) self[step] = () => self
    return self
  }
  return {
    from(table: string) {
      tables.push(table)
      const queued = queues[table]?.shift()
      if (!queued) throw new Error(`fake client: no reply queued for "${table}"`)
      return builder(queued)
    },
  } as unknown as SupabaseClient
}

describe('supabaseStore.findAssetByTag', () => {
  it('throws, naming the tag, when the asset lookup itself errors', async () => {
    const store = supabaseStore(fakeClient({ assets: [{ data: null, error: { message: 'fetch failed' } }] }))

    await expect(store.findAssetByTag('company-1', 'B006')).rejects.toThrow(/B006[\s\S]*fetch failed/)
  })

  it('returns null when the lookup succeeds and no row carries the tag', async () => {
    const store = supabaseStore(fakeClient({ assets: [{ data: null, error: null }] }))

    await expect(store.findAssetByTag('company-1', 'B006')).resolves.toBeNull()
  })

  it('reports the open assignment of the row it found', async () => {
    const store = supabaseStore(
      fakeClient({
        assets: [{ data: { id: 'asset-1' }, error: null }],
        asset_assignments: [{ data: [{ person_id: 'person-2' }], error: null }],
      }),
    )

    await expect(store.findAssetByTag('company-1', 'B006')).resolves.toEqual({
      id: 'asset-1',
      openAssignment: { personId: 'person-2' },
    })
  })
})

describe('supabaseStore.markAssigned', () => {
  it('reads the status back after the update instead of trusting it', async () => {
    const tables: string[] = []
    const store = supabaseStore(
      fakeClient(
        { assets: [{ data: null, error: null }, { data: { status: 'available' }, error: null }] },
        tables,
      ),
    )

    // The update reported no error, yet the row still reads `available`:
    // exactly what the app.asset_transition guard does to a plain UPDATE.
    await expect(store.markAssigned('asset-1')).resolves.toEqual({ error: null, status: 'available' })
    expect(tables).toEqual(['assets', 'assets']) // the update, then the read-back
  })

  it('reports the failure rather than a status when the update errors', async () => {
    const store = supabaseStore(fakeClient({ assets: [{ data: null, error: { message: 'connection reset' } }] }))

    await expect(store.markAssigned('asset-1')).resolves.toEqual({ error: { message: 'connection reset' } })
  })
})
