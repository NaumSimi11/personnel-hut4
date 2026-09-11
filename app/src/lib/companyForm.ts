import { z } from 'zod'

/**
 * Company profile form boundary. The database owns uniqueness
 * (companies.short_code), the brand colour check, and authorization (RLS:
 * platform admins only); this file validates shape, maps between the form
 * and the row, and translates database refusals for the UI.
 */

export const SHORT_CODE_MIN = 2
export const SHORT_CODE_MAX = 6
export const DEFAULT_ACCENT = '#2f5d4f'

const optionalText = (max: number) => z.string().trim().max(max, 'Too long.')
const optionalUuid = z.union([z.literal(''), z.string().uuid('Choose a person from the list.')])

const website = z
  .string()
  .trim()
  .transform((raw) => (raw && !/^https?:\/\//i.test(raw) ? `https://${raw}` : raw))
  .refine((value) => value === '' || isWebUrl(value), 'Enter a valid web address.')

function isWebUrl(value: string): boolean {
  try {
    const url = new URL(value)
    return (url.protocol === 'http:' || url.protocol === 'https:') && url.hostname.includes('.')
  } catch {
    return false
  }
}

export const companyInput = z.object({
  name: z.string().trim().min(2, 'Enter the company name.').max(120, 'Company name is too long.'),
  shortCode: z
    .string()
    .trim()
    .toUpperCase()
    .regex(
      new RegExp(`^[A-Z0-9]{${SHORT_CODE_MIN},${SHORT_CODE_MAX}}$`),
      'Short code: 2–6 letters or digits.',
    ),
  tagline: optionalText(160),
  website,
  accentColor: z.union([
    z.literal(''),
    z.string().trim().regex(/^#[0-9a-fA-F]{6}$/, 'Accent colour must be a hex value like #3e744e.'),
  ]),
  legalName: optionalText(200),
  registrationNumber: optionalText(60),
  taxId: optionalText(60),
  addressLine1: optionalText(200),
  addressLine2: optionalText(200),
  city: optionalText(100),
  postcode: optionalText(20),
  country: optionalText(100),
  contactEmail: z.union([
    z.literal(''),
    z.string().trim().toLowerCase().email('Enter a valid contact email.'),
  ]),
  contactPhone: optionalText(40),
  directorPersonId: optionalUuid,
  hrContactPersonId: optionalUuid,
})

export type CompanyInput = z.infer<typeof companyInput>
export type CompanyForm = z.input<typeof companyInput>

export type CompanyBrand = {
  logo_path?: string
  accent_color?: string
  tagline?: string
}

/** The columns the profile form reads and writes. */
export type CompanyProfileRow = {
  id: string
  parent_company_id: string | null
  kind: string
  name: string
  short_code: string
  legal_name: string | null
  registration_number: string | null
  tax_id: string | null
  address_line1: string | null
  address_line2: string | null
  city: string | null
  postcode: string | null
  country: string | null
  website: string | null
  contact_email: string | null
  contact_phone: string | null
  director_person_id: string | null
  hr_contact_person_id: string | null
  brand: unknown
  archived_at: string | null
}

export const COMPANY_PROFILE_SELECT = `id, parent_company_id, kind, name, short_code,
  legal_name, registration_number, tax_id, address_line1, address_line2, city, postcode, country,
  website, contact_email, contact_phone, director_person_id, hr_contact_person_id, brand, archived_at`

export function emptyCompanyForm(): CompanyForm {
  return {
    name: '',
    shortCode: '',
    tagline: '',
    website: '',
    accentColor: '',
    legalName: '',
    registrationNumber: '',
    taxId: '',
    addressLine1: '',
    addressLine2: '',
    city: '',
    postcode: '',
    country: '',
    contactEmail: '',
    contactPhone: '',
    directorPersonId: '',
    hrContactPersonId: '',
  }
}

/** brand is untyped jsonb in the generated types; read it defensively. */
export function brandOf(row: { brand: unknown }): CompanyBrand {
  const raw = row.brand
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {}
  const record = raw as Record<string, unknown>
  const pick = (key: keyof CompanyBrand) => {
    const value = record[key]
    return typeof value === 'string' ? value : undefined
  }
  return {
    ...(pick('logo_path') && { logo_path: pick('logo_path') }),
    ...(pick('accent_color') && { accent_color: pick('accent_color') }),
    ...(pick('tagline') && { tagline: pick('tagline') }),
  }
}

export function formFromCompany(row: CompanyProfileRow): CompanyForm {
  const brand = brandOf(row)
  return {
    name: row.name,
    shortCode: row.short_code,
    tagline: brand.tagline ?? '',
    website: row.website ?? '',
    accentColor: brand.accent_color ?? '',
    legalName: row.legal_name ?? '',
    registrationNumber: row.registration_number ?? '',
    taxId: row.tax_id ?? '',
    addressLine1: row.address_line1 ?? '',
    addressLine2: row.address_line2 ?? '',
    city: row.city ?? '',
    postcode: row.postcode ?? '',
    country: row.country ?? '',
    contactEmail: row.contact_email ?? '',
    contactPhone: row.contact_phone ?? '',
    directorPersonId: row.director_person_id ?? '',
    hrContactPersonId: row.hr_contact_person_id ?? '',
  }
}

const orNull = (value: string): string | null => (value === '' ? null : value)

/**
 * The row to write for validated input. The logo is uploaded separately and
 * recorded via its own update, so the existing logo_path is carried over
 * untouched; every other brand key is replaced by the form's value.
 */
export function rowFromForm(input: CompanyInput, existingBrand: CompanyBrand) {
  const brand: CompanyBrand = {
    ...(existingBrand.logo_path && { logo_path: existingBrand.logo_path }),
    ...(input.accentColor && { accent_color: input.accentColor.toLowerCase() }),
    ...(input.tagline && { tagline: input.tagline }),
  }
  return {
    name: input.name,
    short_code: input.shortCode,
    legal_name: orNull(input.legalName),
    registration_number: orNull(input.registrationNumber),
    tax_id: orNull(input.taxId),
    address_line1: orNull(input.addressLine1),
    address_line2: orNull(input.addressLine2),
    city: orNull(input.city),
    postcode: orNull(input.postcode),
    country: orNull(input.country),
    website: orNull(input.website),
    contact_email: orNull(input.contactEmail),
    contact_phone: orNull(input.contactPhone),
    director_person_id: orNull(input.directorPersonId),
    hr_contact_person_id: orNull(input.hrContactPersonId),
    brand,
  }
}

export function friendlyCompanyError(message: string): string {
  if (/companies_short_code_key/.test(message)) {
    return 'That short code is already used by another company.'
  }
  if (/row-level security/.test(message)) {
    return 'Only platform admins can change companies.'
  }
  return message
}
