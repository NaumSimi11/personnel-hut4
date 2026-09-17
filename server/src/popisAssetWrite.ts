/**
 * The write sequence for one imported asset — pulled out of the import
 * script so it has tests that do not touch a real database.
 *
 * The original sequence set `status: 'assigned'` in the same insert as the
 * asset row, then inserted the assignment as a separate statement. If that
 * second insert failed, the asset was left permanently `assigned` with no
 * row saying to whom — and a re-run's unique-constraint hit on the asset
 * insert took a `continue` branch that skipped the assignment entirely, so
 * nothing could ever repair it.
 *
 * Here every asset is created `available`; only a successfully-inserted
 * assignment promotes it to `assigned`. A failure at any point leaves a
 * state that is wrong (unassigned when it should be assigned) but never a
 * lie (assigned with nobody recorded) — and because a duplicate asset_tag
 * is reconciled to the existing row instead of skipped, a re-run backfills
 * a missing assignment rather than silently giving up on it.
 */

export type NewAssetRow = {
  readonly company_id: string
  readonly asset_tag: string
  readonly type_key: string
  readonly model: string
  readonly note: string
}

export type WriteItem = {
  readonly asset: NewAssetRow
  readonly personId: string | null
}

export type WriteResult =
  | { readonly outcome: 'created' | 'reconciled'; readonly assigned: boolean; readonly warning?: string }
  | { readonly outcome: 'failed'; readonly message: string }

/** What `writeAsset` needs from a database — a real Supabase client, or a fake in tests. */
export type AssetStore = {
  insertAsset(
    row: NewAssetRow & { readonly status: 'available' },
  ): Promise<
    | { readonly id: string; readonly error: null }
    | { readonly id: null; readonly error: { readonly code?: string; readonly message: string } }
  >
  findAssetByTag(companyId: string, assetTag: string): Promise<{ readonly id: string } | null>
  insertAssignment(assetId: string, personId: string): Promise<{ readonly error: { readonly message: string } | null }>
  markAssigned(assetId: string): Promise<{ readonly error: { readonly message: string } | null }>
}

const UNIQUE_VIOLATION = '23505' // Postgres SQLSTATE for a unique-constraint hit.

type Placed = { readonly outcome: 'created' | 'reconciled'; readonly id: string }

/**
 * Resolves the asset insert's outcome without mutating anything it's given:
 * a clean insert is `created`; a duplicate asset_tag is looked up and
 * `reconciled` to the row that already exists; anything else is a real
 * failure.
 */
async function placeAsset(
  store: AssetStore,
  asset: NewAssetRow,
  inserted: Awaited<ReturnType<AssetStore['insertAsset']>>,
): Promise<Placed | { readonly message: string }> {
  if (!inserted.error) return { outcome: 'created', id: inserted.id }
  if (inserted.error.code !== UNIQUE_VIOLATION) return { message: inserted.error.message }

  const existing = await store.findAssetByTag(asset.company_id, asset.asset_tag)
  if (!existing) {
    return { message: `duplicate asset_tag "${asset.asset_tag}" but no existing row was found to reconcile to` }
  }
  return { outcome: 'reconciled', id: existing.id }
}

/** Writes one asset, and its assignment if it has a person holder. */
export async function writeAsset(store: AssetStore, item: WriteItem): Promise<WriteResult> {
  const inserted = await store.insertAsset({ ...item.asset, status: 'available' })
  const placed = await placeAsset(store, item.asset, inserted)
  if ('message' in placed) return { outcome: 'failed', message: placed.message }

  if (!item.personId) return { outcome: placed.outcome, assigned: false }

  const assignment = await store.insertAssignment(placed.id, item.personId)
  if (assignment.error) {
    return { outcome: placed.outcome, assigned: false, warning: `assignment failed: ${assignment.error.message}` }
  }

  const marked = await store.markAssigned(placed.id)
  if (marked.error) {
    return { outcome: placed.outcome, assigned: false, warning: `could not mark assigned: ${marked.error.message}` }
  }
  return { outcome: placed.outcome, assigned: true }
}

export type WriteSummary = {
  readonly created: number
  readonly reconciled: number
  readonly failed: number
  readonly assigned: number
}

/** Folds a batch of results into the three-way outcome count plus how many ended up assigned. */
export function summarizeWrites(results: readonly WriteResult[]): WriteSummary {
  return results.reduce<WriteSummary>(
    (totals, result) => ({
      created: totals.created + (result.outcome === 'created' ? 1 : 0),
      reconciled: totals.reconciled + (result.outcome === 'reconciled' ? 1 : 0),
      failed: totals.failed + (result.outcome === 'failed' ? 1 : 0),
      assigned: totals.assigned + ('assigned' in result && result.assigned ? 1 : 0),
    }),
    { created: 0, reconciled: 0, failed: 0, assigned: 0 },
  )
}
