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
  const holder = asset.holder_id ? (lookups.holders[asset.holder_id] ?? '—') : WAREHOUSE
  const model = (asset.model ?? '').trim()
  return [type, company, model, holder].filter((part) => part !== '').join(' · ')
}
