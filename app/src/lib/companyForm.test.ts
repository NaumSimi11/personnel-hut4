import { describe, expect, it } from 'vitest'
import {
  companyInput,
  emptyCompanyForm,
  formFromCompany,
  friendlyCompanyError,
  rowFromForm,
  type CompanyProfileRow,
} from './companyForm'

const minimal = { ...emptyCompanyForm(), name: 'Snowball', shortCode: 'snow' }

describe('companyInput', () => {
  it('accepts a name and short code, trimming and upper-casing the code', () => {
    const parsed = companyInput.safeParse({ ...minimal, name: '  Snowball  ', shortCode: ' snow ' })
    expect(parsed.success).toBe(true)
    if (parsed.success) {
      expect(parsed.data.name).toBe('Snowball')
      expect(parsed.data.shortCode).toBe('SNOW')
    }
  })

  it('rejects a name shorter than two characters', () => {
    const parsed = companyInput.safeParse({ ...minimal, name: 'A' })
    expect(parsed.success).toBe(false)
    if (!parsed.success) expect(parsed.error.issues[0]?.message).toBe('Enter the company name.')
  })

  it('rejects a short code outside 2–6 characters', () => {
    expect(companyInput.safeParse({ ...minimal, shortCode: 'A' }).success).toBe(false)
    expect(companyInput.safeParse({ ...minimal, shortCode: 'ABCDEFG' }).success).toBe(false)
  })

  it('rejects a short code with characters other than letters and digits', () => {
    const parsed = companyInput.safeParse({ ...minimal, shortCode: 'AC-1' })
    expect(parsed.success).toBe(false)
    if (!parsed.success) {
      expect(parsed.error.issues[0]?.message).toBe('Short code: 2–6 letters or digits.')
    }
  })

  it('leaves every optional field empty when not given', () => {
    const parsed = companyInput.safeParse(minimal)
    expect(parsed.success).toBe(true)
    if (parsed.success) {
      expect(parsed.data.website).toBe('')
      expect(parsed.data.directorPersonId).toBe('')
      expect(parsed.data.accentColor).toBe('')
    }
  })

  it('adds https:// to a bare website domain', () => {
    const parsed = companyInput.safeParse({ ...minimal, website: 'snowball.example' })
    expect(parsed.success).toBe(true)
    if (parsed.success) expect(parsed.data.website).toBe('https://snowball.example')
  })

  it('rejects a website that is not a web address', () => {
    const parsed = companyInput.safeParse({ ...minimal, website: 'not a url' })
    expect(parsed.success).toBe(false)
    if (!parsed.success) expect(parsed.error.issues[0]?.message).toBe('Enter a valid web address.')
  })

  it('accepts a six-digit hex accent colour and rejects anything else', () => {
    expect(companyInput.safeParse({ ...minimal, accentColor: '#3E744E' }).success).toBe(true)
    const bad = companyInput.safeParse({ ...minimal, accentColor: 'green' })
    expect(bad.success).toBe(false)
    if (!bad.success) expect(bad.error.issues[0]?.message).toBe('Accent colour must be a hex value like #3e744e.')
  })

  it('validates the contact email when present', () => {
    expect(companyInput.safeParse({ ...minimal, contactEmail: 'Hello@Snow.Example' }).success).toBe(true)
    const bad = companyInput.safeParse({ ...minimal, contactEmail: 'nope' })
    expect(bad.success).toBe(false)
    if (!bad.success) expect(bad.error.issues[0]?.message).toBe('Enter a valid contact email.')
  })

  it('requires director and HR contact to be person ids when set', () => {
    expect(companyInput.safeParse({ ...minimal, directorPersonId: 'abc' }).success).toBe(false)
    expect(
      companyInput.safeParse({ ...minimal, hrContactPersonId: '20000000-0000-0000-0000-000000000001' }).success,
    ).toBe(true)
  })
})

const row: CompanyProfileRow = {
  id: 'c1',
  parent_company_id: 'h1',
  kind: 'company',
  name: 'Snowball',
  short_code: 'SNOW',
  legal_name: 'Snowball d.o.o.',
  registration_number: 'REG-1',
  tax_id: null,
  address_line1: '1 Main St',
  address_line2: null,
  city: 'Skopje',
  postcode: '1000',
  country: 'North Macedonia',
  website: 'https://snowball.example',
  contact_email: 'hello@snowball.example',
  contact_phone: null,
  director_person_id: '20000000-0000-0000-0000-000000000001',
  hr_contact_person_id: null,
  brand: { accent_color: '#3e744e', tagline: 'We build things', logo_path: 'c1/logo.png' },
  archived_at: null,
  country_code: 'MK',
  leave_entitlement_days: 22,
  leave_carry_over_until: '06-30',
}

describe('formFromCompany', () => {
  it('maps every column and brand key to a form field, nulls becoming empty strings', () => {
    const form = formFromCompany(row)
    expect(form.name).toBe('Snowball')
    expect(form.legalName).toBe('Snowball d.o.o.')
    expect(form.taxId).toBe('')
    expect(form.directorPersonId).toBe('20000000-0000-0000-0000-000000000001')
    expect(form.hrContactPersonId).toBe('')
    expect(form.accentColor).toBe('#3e744e')
    expect(form.tagline).toBe('We build things')
  })

  it('tolerates a brand object with no keys', () => {
    const form = formFromCompany({ ...row, brand: {} })
    expect(form.accentColor).toBe('')
    expect(form.tagline).toBe('')
  })
})

describe('leave settings', () => {
  it('maps the country code and leave defaults both ways', () => {
    const form = formFromCompany(row)
    expect(form.countryCode).toBe('MK')
    expect(form.leaveEntitlementDays).toBe('22')
    expect(form.leaveCarryOverUntil).toBe('06-30')
    const out = rowFromForm(companyInput.parse({ ...minimal, countryCode: 'rs', leaveEntitlementDays: '25', leaveCarryOverUntil: '03-31' }), {})
    expect(out.country_code).toBe('RS')
    expect(out.leave_entitlement_days).toBe(25)
    expect(out.leave_carry_over_until).toBe('03-31')
    expect(rowFromForm(companyInput.parse(minimal), {}).country_code).toBeNull()
  })

  it('refuses a bad country code, a negative entitlement or a malformed carry-over date', () => {
    expect(companyInput.safeParse({ ...minimal, countryCode: 'Mac' }).success).toBe(false)
    expect(companyInput.safeParse({ ...minimal, leaveEntitlementDays: '-1' }).success).toBe(false)
    expect(companyInput.safeParse({ ...minimal, leaveCarryOverUntil: '31-03' }).success).toBe(false)
    expect(companyInput.safeParse({ ...minimal, leaveCarryOverUntil: '' }).success).toBe(false)
    // The columns are int 0–100 and a date that exists every year.
    expect(companyInput.safeParse({ ...minimal, leaveEntitlementDays: '22.5' }).success).toBe(false)
    expect(companyInput.safeParse({ ...minimal, leaveEntitlementDays: '150' }).success).toBe(false)
    expect(companyInput.safeParse({ ...minimal, leaveCarryOverUntil: '02-29' }).success).toBe(false)
    expect(companyInput.safeParse({ ...minimal, leaveCarryOverUntil: '04-31' }).success).toBe(false)
    expect(companyInput.safeParse({ ...minimal, leaveCarryOverUntil: '12-31' }).success).toBe(true)
  })
})

describe('rowFromForm', () => {
  it('turns empty strings into nulls and builds the brand object', () => {
    const parsed = companyInput.parse({ ...minimal, accentColor: '#3e744e', tagline: ' Hi ' })
    const out = rowFromForm(parsed, {})
    expect(out.legal_name).toBeNull()
    expect(out.director_person_id).toBeNull()
    expect(out.short_code).toBe('SNOW')
    expect(out.brand).toEqual({ accent_color: '#3e744e', tagline: 'Hi' })
  })

  it('keeps the existing logo_path the form never edits', () => {
    const parsed = companyInput.parse(minimal)
    const out = rowFromForm(parsed, { logo_path: 'c1/logo.png', accent_color: '#000000' })
    expect(out.brand).toEqual({ logo_path: 'c1/logo.png' })
  })
})

describe('friendlyCompanyError', () => {
  it('maps a short_code unique violation', () => {
    expect(
      friendlyCompanyError('duplicate key value violates unique constraint "companies_short_code_key"'),
    ).toBe('That short code is already used by another company.')
  })

  it('maps a row-level security denial', () => {
    expect(
      friendlyCompanyError('new row violates row-level security policy for table "companies"'),
    ).toBe('Only platform admins can change companies.')
  })

  it('passes other messages through unchanged', () => {
    expect(friendlyCompanyError('network down')).toBe('network down')
  })
})
