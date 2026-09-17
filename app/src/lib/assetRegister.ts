/**
 * One line describing an asset in the holding-wide register.
 *
 * The register is read across companies, so a row has to say which company
 * owns a thing and who has it without the reader consulting a filter. An
 * asset nobody holds says "magacin" — the warehouse — because a blank reads
 * as missing information rather than as a fact.
 */
export type RegisterAsset = {
  readonly type_key: string
  readonly company_id: string | null
  readonly holder_id: string | null
  readonly model: string | null
  /** Who the imported books say holds it, when no person is linked here. */
  readonly holder_note?: string | null
}

export type RegisterLookups = {
  readonly types: Readonly<Record<string, string>>
  readonly companies: Readonly<Record<string, string>>
  readonly holders: Readonly<Record<string, string>>
}

export const WAREHOUSE = 'magacin'

export function assetLine(asset: RegisterAsset, lookups: RegisterLookups): string {
  const type = lookups.types[asset.type_key] ?? asset.type_key
  const company = asset.company_id ? (lookups.companies[asset.company_id] ?? '—') : 'Holding pool'
  // An asset nobody is assigned to is not necessarily in the warehouse. The
  // imported books often name a holder this system cannot match to a person —
  // a diminutive, initials, or a place. Saying "magacin" there would claim the
  // thing is free to hand out when someone has it.
  const claimed = (asset.holder_note ?? '').trim()
  const holder = asset.holder_id
    ? (lookups.holders[asset.holder_id] ?? '—')
    : claimed
      ? `${claimed} (from the books, not matched)`
      : WAREHOUSE
  const model = (asset.model ?? '').trim()
  return [type, company, model, holder].filter((part) => part !== '').join(' · ')
}

/**
 * The two numbers printed on the physical label: the Шифра and the Инв. бр.
 * They are different identifiers — the second is what the accounts reconcile a
 * попис against — and a register that shows only one cannot be checked against
 * the thing in your hand.
 */
export function assetNumbers(asset: {
  readonly asset_tag: string
  readonly inventory_number?: string | null
}): string {
  const inventory = (asset.inventory_number ?? '').trim()
  return inventory ? `${asset.asset_tag} · инв. ${inventory}` : asset.asset_tag
}
