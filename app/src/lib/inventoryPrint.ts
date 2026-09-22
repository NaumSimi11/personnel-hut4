import { assetStatusLabel } from '@/lib/equipment'

/**
 * The printed equipment register (task.md: "equipment - print inventory list").
 *
 * It prints what is on screen — the same filtered, sorted list — because a
 * register printed for one company or one holder is the usual reason to print
 * one at all. Shaping only: the page owns the filters, this owns the cells.
 */

/** An asset with no company belongs to the holding rather than to one company. */
export const POOL_OWNER_LABEL = 'Holding pool'
/** Every empty cell reads the same, so a gap is never mistaken for a missing column. */
export const BLANK = '—'

export type InventoryAsset = {
  asset_tag: string
  type_key: string
  model: string | null
  serial_number: string | null
  inventory_number: string | null
  company_id: string | null
  status: string
  holder_note: string | null
  /** The live assignment's holder, when there is one. */
  holderName: string | null
}

export type InventoryNames = {
  types: Record<string, string>
  companies: Record<string, string>
}

export type InventoryRow = {
  tag: string
  type: string
  model: string
  serial: string
  inventory: string
  owner: string
  status: string
  holder: string
}

function cell(value: string | null | undefined): string {
  const text = (value ?? '').trim()
  return text === '' ? BLANK : text
}

/**
 * Who holds it: the live assignment first, then what the books say
 * (`holder_note`), which is the only record for the rows imported from them.
 */
function holderCell(asset: InventoryAsset): string {
  if (asset.holderName) return asset.holderName
  const note = (asset.holder_note ?? '').trim()
  return note === '' ? BLANK : `${note} (per the books)`
}

export function inventoryRows(
  assets: ReadonlyArray<InventoryAsset>,
  names: InventoryNames,
): InventoryRow[] {
  return assets.map((a) => ({
    tag: cell(a.asset_tag),
    type: cell(names.types[a.type_key] ?? a.type_key),
    model: cell(a.model),
    serial: cell(a.serial_number),
    inventory: cell(a.inventory_number),
    owner: a.company_id === null ? POOL_OWNER_LABEL : cell(names.companies[a.company_id]),
    status: cell(assetStatusLabel(a.status)),
    holder: holderCell(a),
  }))
}

/**
 * Today as the person printing it sees it, "YYYY-MM-DD".
 *
 * `todayDb()` slices an ISO string and is therefore UTC, which is right for
 * rows compared against stored dates and wrong for a stamp on paper: printed
 * at half past midnight here, a UTC stamp would date the page yesterday.
 */
export function localToday(now = new Date()): string {
  const pad = (n: number): string => String(n).padStart(2, '0')
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

/** The line under the heading, so a printed page says what it is and when it was true. */
export function inventoryHeading(count: number, printedOn: string): string {
  return `${count} item${count === 1 ? '' : 's'} · printed ${printedOn}`
}
