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
 *
 * What makes a re-run safe, explicitly, because the whole resumability of
 * this import rests on it: there is no separate idempotency key. The natural
 * key is the database's `unique (company_id, asset_tag)` on `assets` — a
 * second run's insert of the same row is rejected, and that rejection is
 * what lets us recognise our own earlier work and carry on from it. The
 * assignment step is then guarded by the open-assignment lookup below, so a
 * retry neither duplicates an issue nor overwrites someone else's.
 *
 * What would break it: anything that changes the asset_tag a row produces.
 * Tags taken from the spreadsheet are stable, but the import invents a tag
 * (`SHEET-0007`) for rows without one, and that fallback is only stable
 * while the review file and the order of items inside it are unchanged.
 * Re-reading the workbook, adding, removing or reordering rows renumbers
 * those items, and the re-run then inserts duplicates of them instead of
 * reconciling. A re-run must use the same review file as the run it resumes.
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

/** An assignment that has not been returned, i.e. the asset is out with this person now. */
export type OpenAssignment = { readonly personId: string }

/** What `writeAsset` needs from a database — a real Supabase client, or a fake in tests. */
export type AssetStore = {
  insertAsset(
    row: NewAssetRow & { readonly status: 'available' },
  ): Promise<
    | { readonly id: string; readonly error: null }
    | { readonly id: null; readonly error: { readonly code?: string; readonly message: string } }
  >
  /**
   * The asset already carrying this tag, plus whoever currently holds it.
   * `openAssignment` is optional only so a test double may leave it out;
   * a real store must report it, because omitting it reads as "nobody holds
   * this asset" and would let a retry issue the same asset twice.
   */
  findAssetByTag(
    companyId: string,
    assetTag: string,
  ): Promise<{ readonly id: string; readonly openAssignment?: OpenAssignment | null } | null>
  insertAssignment(assetId: string, personId: string): Promise<{ readonly error: { readonly message: string } | null }>
  /**
   * Sets the asset's status to `assigned` and reports the status the row
   * carries afterwards. `status` is optional only so a test double may leave
   * it out; a real store must report it, because an UPDATE on `assets` can
   * report success and still not stick — `app.prepare_asset` puts the old
   * status back whenever `auth.uid()` is non-null and `app.asset_transition`
   * is not `'on'`, silently and without an error.
   */
  markAssigned(assetId: string): Promise<{
    readonly error: { readonly message: string } | null
    readonly status?: string | null
  }>
}

const UNIQUE_VIOLATION = '23505' // Postgres SQLSTATE for a unique-constraint hit.

type Placed = {
  readonly outcome: 'created' | 'reconciled'
  readonly id: string
  readonly openAssignment: OpenAssignment | null
}

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
  // A freshly created asset cannot already be assigned, so only the
  // reconcile branch has to care about what a previous run left behind.
  if (!inserted.error) return { outcome: 'created', id: inserted.id, openAssignment: null }
  if (inserted.error.code !== UNIQUE_VIOLATION) return { message: inserted.error.message }

  const existing = await store.findAssetByTag(asset.company_id, asset.asset_tag)
  if (!existing) {
    return { message: `duplicate asset_tag "${asset.asset_tag}" but no existing row was found to reconcile to` }
  }
  return { outcome: 'reconciled', id: existing.id, openAssignment: existing.openAssignment ?? null }
}

/**
 * Whether the assignment step still has work to do on a reconciled asset.
 * An asset already out with the same person means an earlier run got this
 * far and only the status update is missing; one out with somebody else is a
 * disagreement between the spreadsheet and the database that no import is
 * entitled to settle by itself.
 */
function assignmentStep(
  placed: Placed,
  personId: string,
): { readonly insert: boolean } | { readonly message: string } {
  const open = placed.openAssignment
  if (!open) return { insert: true }
  if (open.personId === personId) return { insert: false }
  return {
    message:
      `asset is already assigned to person ${open.personId}, ` +
      `but the import assigns it to person ${personId} — resolve this by hand; nothing was written`,
  }
}

/** Writes one asset, and its assignment if it has a person holder. */
export async function writeAsset(store: AssetStore, item: WriteItem): Promise<WriteResult> {
  const inserted = await store.insertAsset({ ...item.asset, status: 'available' })
  const placed = await placeAsset(store, item.asset, inserted)
  if ('message' in placed) return { outcome: 'failed', message: placed.message }

  if (!item.personId) return { outcome: placed.outcome, assigned: false }

  const step = assignmentStep(placed, item.personId)
  if ('message' in step) return { outcome: 'failed', message: step.message }

  if (step.insert) {
    const assignment = await store.insertAssignment(placed.id, item.personId)
    if (assignment.error) {
      return { outcome: placed.outcome, assigned: false, warning: `assignment failed: ${assignment.error.message}` }
    }
  }

  const marked = await store.markAssigned(placed.id)
  if (marked.error) {
    return { outcome: placed.outcome, assigned: false, warning: `could not mark assigned: ${marked.error.message}` }
  }
  // An UPDATE that reports no error is not proof the status changed, so the
  // count of assigned assets is only trustworthy if the row is read back.
  // A wrong number that announces itself can still be repaired by hand.
  if (marked.status !== undefined && marked.status !== 'assigned') {
    return {
      outcome: 'failed',
      message:
        `the status update did not take effect — the asset still reads "${marked.status ?? 'unknown'}" ` +
        `after markAssigned; the likely cause is the app.asset_transition guard in app.prepare_asset, ` +
        `which puts the old status back on any UPDATE made by an authenticated role`,
    }
  }
  return { outcome: placed.outcome, assigned: true }
}

export type WriteSheet = {
  readonly sheet: string
  readonly items: readonly WriteItem[]
}

/** One row's fate, handed to the caller the moment it lands. */
export type WriteRow = {
  readonly sheet: string
  readonly tag: string
  readonly result: WriteResult
}

const quoted = (text: string): string => `"${text}"`

/** The models, in sheet order, that each tag of one sheet is claimed by. */
function modelsByTag(sheet: WriteSheet): ReadonlyMap<string, readonly string[]> {
  const claims = new Map<string, readonly string[]>()
  for (const item of sheet.items) {
    const seen = claims.get(item.asset.asset_tag) ?? []
    claims.set(item.asset.asset_tag, [...seen, item.asset.model])
  }
  return claims
}

/**
 * Refuses a run in which one sheet gives the same asset tag to two items.
 *
 * The database's `unique (company_id, asset_tag)` would not reject the second
 * one as an error the operator can see: `writeAsset` reconciles a duplicate
 * tag onto the row that already carries it, which is exactly right for a
 * re-run but silently discards a *different* item's type, model and note —
 * leaving a register one asset short of what the dry run promised, with only
 * "reconciled 1" in the summary to show for it. The register is about to be
 * signed for, so a missing asset must stop the run, not shorten the count.
 *
 * Refusing is the only honest answer: the import cannot know which of the two
 * items should keep the tag. A human gives the other one a tag of its own in
 * the review file.
 */
export function assertUniqueAssetTags(sheets: readonly WriteSheet[]): void {
  const conflicts = sheets.flatMap((sheet) =>
    [...modelsByTag(sheet).entries()]
      .filter(([, models]) => models.length > 1)
      .map(([tag, models]) => `sheet "${sheet.sheet}" tag "${tag}": ${models.map((m) => quoted(m)).join(' and ')}`),
  )
  if (!conflicts.length) return
  throw new Error(
    `Refusing: ${conflicts.length} asset tag(s) claimed by more than one item — ${conflicts.join('; ')}. ` +
      `Each tag names exactly one asset, so every item after the first would be folded onto that asset ` +
      `and its own type, model and note lost. The import cannot choose which item keeps the tag: ` +
      `give the others a tag of their own in the review file by hand, then run again.`,
  )
}

/**
 * Writes every item of every sheet, in order, reporting each row through
 * `onRow` as it lands — a run interrupted half-way still says how far it got,
 * which is the only record anybody has of a one-off import.
 */
export async function writeSheets(
  store: AssetStore,
  sheets: readonly WriteSheet[],
  onRow: (row: WriteRow) => void,
): Promise<readonly WriteResult[]> {
  assertUniqueAssetTags(sheets) // before the first write, so a refusal changes nothing

  const results: WriteResult[] = []
  for (const sheet of sheets) {
    for (const item of sheet.items) {
      const result = await writeAsset(store, item)
      onRow({ sheet: sheet.sheet, tag: item.asset.asset_tag, result })
      results.push(result)
    }
  }
  return results
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
