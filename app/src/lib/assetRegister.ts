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
  /** What the thing is, when its type is 'other'. */
  readonly type_note?: string | null
}

export type RegisterLookups = {
  readonly types: Readonly<Record<string, string>>
  readonly companies: Readonly<Record<string, string>>
  readonly holders: Readonly<Record<string, string>>
}

export const WAREHOUSE = 'magacin'

export function assetLine(asset: RegisterAsset, lookups: RegisterLookups): string {
  // "Other" on its own tells the reader nothing, so whatever was written in its
  // place is what the register prints.
  const written = (asset.type_note ?? '').trim()
  const type =
    asset.type_key === 'other' && written ? written : (lookups.types[asset.type_key] ?? asset.type_key)
  const company = asset.company_id ? (lookups.companies[asset.company_id] ?? '—') : 'Shared'
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
 * The two numbers printed on the physical label: the asset tag (Шифра on
 * the company's own lists) and the inventory number (Инв. бр.).
 * They are different identifiers — the second is what the accounts reconcile a
 * попис against — and a register that shows only one cannot be checked against
 * the thing in your hand.
 */
export function assetNumbers(asset: {
  readonly asset_tag: string
  readonly inventory_number?: string | null
}): string {
  const inventory = (asset.inventory_number ?? '').trim()
  return inventory ? `${asset.asset_tag} · inv. ${inventory}` : asset.asset_tag
}

/** The select's value when the holder is not a person in this system. */
export const OTHER_HOLDER = '__other'
/** The select's value for putting the asset back in the warehouse. */
export const NOBODY = '__nobody'

/**
 * What a holder selection means.
 *
 * Equipment does not only go to people. The imported books hand assets to
 * "office", "office Struga", "sluzbeno vozilo" and a trademark, and name
 * holders this system has no person for — initials, or someone at a company
 * that is not in the app. Forcing that into a person picker is what left 59
 * assets reading as though they sat in the warehouse, free to hand out.
 */
export type HolderChoice =
  | { readonly kind: 'person'; readonly personId: string }
  | { readonly kind: 'other'; readonly text: string }
  | { readonly kind: 'nobody' }
  | { readonly kind: 'invalid'; readonly message: string }

export function holderChoice(selected: string, otherText: string): HolderChoice {
  if (selected === NOBODY) return { kind: 'nobody' }
  if (selected === OTHER_HOLDER) {
    const text = otherText.trim()
    return text ? { kind: 'other', text } : { kind: 'invalid', message: 'Say who or what has it.' }
  }
  if (!selected) return { kind: 'invalid', message: 'Choose who it is for.' }
  return { kind: 'person', personId: selected }
}

/**
 * Whether an asset answers what someone typed.
 *
 * Over a register of 191 rows the question is always "where is A070" or "what
 * does Naum have", so the search looks at everything printed on the row: both
 * numbers from the label, the model, the type, the serial, and whoever holds it
 * — including the name the books give when no person is linked, because those
 * are exactly the rows somebody is hunting for.
 *
 * Every word must match, so a second term narrows rather than widens. Typing
 * more should get you closer to one row, not further from it.
 */
export function matchesSearch(
  asset: {
    readonly asset_tag: string
    readonly inventory_number?: string | null
    readonly model?: string | null
    readonly type_key?: string | null
    readonly holder_note?: string | null
    readonly serial_number?: string | null
  },
  query: string,
  holderName: string | null,
  typeLabel: string | null,
): boolean {
  const words = query.trim().toLowerCase().split(/\s+/).filter((w) => w !== '')
  if (words.length === 0) return true
  const haystack = [
    asset.asset_tag,
    asset.inventory_number,
    asset.model,
    asset.type_key,
    typeLabel,
    asset.serial_number,
    asset.holder_note,
    holderName,
  ]
    .filter((v): v is string => typeof v === 'string' && v !== '')
    .join(' ')
    .toLowerCase()
  return words.every((word) => haystack.includes(word))
}

/**
 * What the books meant by a holder we could not match to a person.
 *
 * The Корисник column was used for *where a thing is* as much as *who has it*.
 * Of 64 unmatched holders, 58 name a place or the company itself — "office",
 * "office Struga", "Synami DOOEL", "sluzbeno vozilo", "vo server B006", even a
 * trademark. Only 6 name a person, and four of those work at a different
 * company from the asset, which is why matching missed them.
 *
 * That difference decides what to do with the row. A laptop sitting in the
 * Struga office is recorded correctly and wants nothing. A laptop the books say
 * Miran Thaqi has is a real person holding real kit that the app does not know
 * about, and somebody should hand it to him properly.
 *
 * So this recognises what is demonstrably not a person and calls everything
 * else a person — the safe way round. A place wrongly called a person puts one
 * extra row in front of somebody who will see it is a place; a person wrongly
 * called a place hides a laptop nobody is accountable for.
 */
export type BookHolder = 'place' | 'company' | 'person'

// Cyrillic and Latin both appear in the books, sometimes in the same cell.
const PLACE_WORDS =
  /(office|kancelarij|канцелариј|magacin|магацин|склад|server|сервер|vozil|возил|sluzben|службен|marka|марка|depo|депо|warehouse)/i
const COMPANY_SUFFIX = /(\bdoo(el)?\b|\bдоо(ел)?\b|\bltd\b|\bd\.?o\.?o\b)/i

export function bookHolder(note: string | null | undefined): BookHolder | null {
  const text = (note ?? '').trim()
  if (text === '') return null
  if (COMPANY_SUFFIX.test(text)) return 'company'
  if (PLACE_WORDS.test(text)) return 'place'
  return 'person'
}

/** The holder filter's value for rows the books put somewhere rather than with someone. */
export const KEPT_SOMEWHERE = '__kept'
/** The holder filter's value for rows naming a person we never matched. */
export const UNMATCHED_PERSON = '__unmatched'
