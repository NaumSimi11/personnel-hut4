/**
 * Picking a free asset for a starter-kit line (plan 072, migration 0092).
 * kit_asset_options lists every available asset in the holding, whoever owns
 * it — the maintainer's one rule is that an asset somebody holds is not
 * offered. This puts the kind of thing the line names first ("Keyboard &
 * mouse" → accessories), narrows by what is typed, and words the options.
 */

export type KitAssetOption = {
  id: string
  asset_tag: string
  model: string | null
  serial_number: string | null
  type_key: string | null
  type_label: string | null
  company_id: string | null
  company_name: string | null
}

/** Words in a kit line that name an asset type, by type key. */
const TYPE_WORDS: Record<string, readonly string[]> = {
  laptop: ['laptop', 'notebook'],
  desktop: ['desktop', 'pc', 'computer', 'workstation'],
  monitor: ['monitor', 'screen', 'display'],
  phone: ['phone', 'mobile', 'smartphone'],
  accessory: ['keyboard', 'mouse', 'headset', 'dock', 'docking', 'adapter', 'cable', 'accessory', 'accessories'],
  software_license: ['software', 'licence', 'licences', 'license', 'licenses'],
  vehicle: ['car', 'vehicle', 'vehicles', 'van'],
  badge: ['badge', 'card', 'keycard', 'pass'],
  furniture: ['desk', 'chair', 'furniture', 'table', 'cabinet', 'drawer'],
}

const PLURAL: Record<string, string> = {
  laptop: 'laptops',
  desktop: 'desktop PCs',
  monitor: 'monitors',
  phone: 'phones',
  accessory: 'accessories',
  software_license: 'software licences',
  vehicle: 'vehicles',
  badge: 'badges',
  furniture: 'furniture items',
}

const DEFAULT_LIMIT = 10

function fold(text: string): string {
  return text.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/ı/g, 'i').toLowerCase()
}

/** The type keys a kit line asks for, from the words in it. */
function typesFor(item: string): Set<string> {
  const words = fold(item).split(/[^a-z0-9]+/).filter(Boolean)
  return new Set(Object.entries(TYPE_WORDS).filter(([, ws]) => ws.some((w) => words.includes(w))).map(([key]) => key))
}

function haystack(o: KitAssetOption): string {
  return fold([o.asset_tag, o.model, o.serial_number, o.type_label, o.company_name ?? 'shared pool'].filter(Boolean).join(' '))
}

/** The line's kind first, then the rest; narrowed by `query`; at most `limit`. */
export function assetSuggestions(
  options: ReadonlyArray<KitAssetOption>,
  item: string,
  query: string,
  limit: number = DEFAULT_LIMIT,
): KitAssetOption[] {
  const wanted = typesFor(item)
  const needle = fold(query.trim())
  return options
    .filter((o) => !needle || haystack(o).includes(needle))
    .map((o, i) => ({ o, i, rank: o.type_key && wanted.has(o.type_key) ? 0 : 1 }))
    .sort((a, b) => a.rank - b.rank || a.i - b.i)
    .slice(0, limit)
    .map(({ o }) => o)
}

/** "LT-0012 · ThinkPad T14 · Laptop · Synami" — the shared pool when nobody owns it. */
export function assetLabel(o: KitAssetOption): string {
  return [o.asset_tag, o.model, o.type_label, o.company_name ?? 'Shared pool'].filter(Boolean).join(' · ')
}

/** The line under a kit item's picker: how much of its kind is free. */
export function kitPickerHint(item: string, options: ReadonlyArray<KitAssetOption>): string {
  if (!options.length) return 'No free equipment in the holding. Tick it without an asset.'
  const wanted = typesFor(item)
  const matching = options.filter((o) => o.type_key && wanted.has(o.type_key))
  if (!matching.length) return 'Nothing of this kind is free. Pick any free asset, or tick it without one.'
  const keys = [...new Set(matching.map((o) => o.type_key as string))]
  const n = matching.length
  const noun = keys.length === 1 ? (n === 1 ? (matching[0]?.type_label ?? 'asset').toLowerCase() : (PLURAL[keys[0] as string] ?? 'assets')) : n === 1 ? 'asset' : 'assets'
  return `${n} free ${noun} in the holding.`
}

/** Whether anything of the line's kind is free — when not, the picker stays folded away. */
export function hasMatchingStock(item: string, options: ReadonlyArray<KitAssetOption>): boolean {
  const wanted = typesFor(item)
  return options.some((o) => o.type_key !== null && wanted.has(o.type_key))
}

export type IssuedAsset = { asset_tag: string; model: string | null; type_label: string | null; company_name: string | null }

/**
 * What an issued line handed out, as the line kept it (0094). A line issued
 * before lines kept their asset knows only that there was one.
 */
export function issuedLabel(item: { asset_id: string | null; asset: IssuedAsset | null }): string | null {
  if (!item.asset_id) return null
  if (!item.asset) return 'a registered asset'
  return [item.asset.asset_tag, item.asset.model, item.asset.type_label, item.asset.company_name].filter(Boolean).join(' · ')
}
