/**
 * The `AssetStore` the popis import writes through, backed by a real Supabase
 * client. It lives beside `popisAssetWrite.ts` rather than inside the import
 * script so that its error handling — the part that decides what the operator
 * is told when a statement misbehaves — has tests of its own. The write path
 * runs exactly once, against production, so every branch here is one nobody
 * gets to rehearse.
 */
import type { SupabaseClient } from '@supabase/supabase-js'
import type { AssetStore } from './popisAssetWrite.js'

export function supabaseStore(client: SupabaseClient): AssetStore {
  return {
    async insertAsset(row) {
      const { data, error } = await client.from('assets').insert(row).select('id').single()
      return error ? { id: null, error: { code: error.code, message: error.message } } : { id: data.id, error: null }
    },

    async updateAsset(assetId, fields) {
      // Reconciling is not merely recognising a row: the first import of this
      // workbook stored no inventory number, because the parser never read the
      // column. A re-run has to bring the row up to the source.
      const { error } = await client.from('assets').update(fields).eq('id', assetId)
      return { error: error ? { message: error.message } : null }
    },

    async findAssetByTag(companyId, assetTag) {
      const { data, error: lookupError } = await client
        .from('assets')
        .select('id')
        .eq('company_id', companyId)
        .eq('asset_tag', assetTag)
        .maybeSingle()
      // A failed read is not an answer. Reporting "no such row" here would
      // have the caller tell the operator their spreadsheet holds a duplicate
      // tag it cannot reconcile — blaming the data for a network fault, at the
      // moment the operator is deciding whether to trust the run.
      if (lookupError) throw new Error(`could not look up asset with tag "${assetTag}": ${lookupError.message}`)
      if (!data) return null

      // An assignment with no returned_at is the asset's current holder.
      const { data: open, error } = await client
        .from('asset_assignments')
        .select('person_id')
        .eq('asset_id', data.id)
        .is('returned_at', null)
        .limit(1)
      // Stop the whole run rather than report "nobody holds it" on a failed
      // lookup: that answer would let the caller issue the asset a second time.
      if (error) throw new Error(`could not read assignments of asset ${data.id}: ${error.message}`)
      return { id: data.id, openAssignment: open?.[0] ? { personId: open[0].person_id } : null }
    },

    async insertAssignment(assetId, personId) {
      const { error } = await client
        .from('asset_assignments')
        .insert({ asset_id: assetId, person_id: personId, issued_at: new Date().toISOString() })
      return { error: error ? { message: error.message } : null }
    },

    async markAssigned(assetId) {
      const { error } = await client.from('assets').update({ status: 'assigned' }).eq('id', assetId)
      if (error) return { error: { message: error.message } }

      // `app.prepare_asset` reverts a status UPDATE silently, without an
      // error, unless it is made outside an authenticated session. The secret
      // key should qualify, but that assumption has never been executed, so
      // the status is read back rather than assumed.
      const { data, error: readError } = await client.from('assets').select('status').eq('id', assetId).maybeSingle()
      if (readError) {
        return { error: { message: `status written but could not be read back: ${readError.message}` } }
      }
      return { error: null, status: data?.status ?? null }
    },
  }
}
