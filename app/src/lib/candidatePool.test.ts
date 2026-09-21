import { describe, expect, it } from 'vitest'
import {
  NOT_ATTACHABLE,
  POOL_PAGE_SIZE,
  SOURCE_FALLBACK_LABEL,
  contactBadge,
  contactLine,
  contactState,
  linkedinKey,
  longDate,
  maskEmail,
  matchHistoryLine,
  matchSentence,
  nameKey,
  phoneKey,
  poolFiltersFromQuery,
  poolPayload,
  poolQuery,
  type CandidateMatch,
  type PoolFilters,
} from './candidatePool'

// The same fixtures the SQL smoke asserts for app.phone_key / name_key /
// linkedin_key / mask_email (supabase/tests/smoke.sql), so the browser
// mirrors never drift from the stored generated keys.
describe('phoneKey', () => {
  it('keeps the last eight digits when at least eight are present', () => {
    expect(phoneKey('077597288')).toBe('77597288')
    expect(phoneKey('+389 70 813 118')).toBe('70813118')
    expect(phoneKey('0038978316858')).toBe('78316858')
  })
  it('is null for short, empty or missing numbers', () => {
    expect(phoneKey('12345')).toBeNull()
    expect(phoneKey('')).toBeNull()
    expect(phoneKey(null)).toBeNull()
    expect(phoneKey(undefined)).toBeNull()
  })
})

describe('nameKey', () => {
  it('lower-cases, drops bracketed parts, sorts the words', () => {
    expect(nameKey('Dimitar (Benjamin) Iliev')).toBe('dimitar iliev')
    expect(nameKey('Iliev Dimitar')).toBe('dimitar iliev')
    expect(nameKey('Iliev [ex-Acme] Dimitar')).toBe('dimitar iliev')
  })
  it('folds Latin diacritics and leaves Cyrillic alone', () => {
    expect(nameKey('Fredrik Möllersten')).toBe('fredrik mollersten')
    expect(nameKey('Петар Петров')).toBe('петар петров')
  })
  it('turns non-letters into spaces and is null when nothing is left', () => {
    expect(nameKey('  Ana-Marija  Ilievska2 ')).toBe('ana ilievska marija')
    expect(nameKey('123 ()')).toBeNull()
    expect(nameKey('')).toBeNull()
    expect(nameKey(null)).toBeNull()
  })
})

describe('linkedinKey', () => {
  it('is the lower-cased /in/ slug without query or trailing slash', () => {
    expect(linkedinKey('https://www.linkedin.com/in/John-Doe/?trk=x')).toBe('john-doe')
    expect(linkedinKey('linkedin.com/in/ana.ilievska')).toBe('ana.ilievska')
    expect(linkedinKey('https://mk.linkedin.com/in/ana#top')).toBe('ana')
  })
  it('is null for anything that is not a linkedin.com profile', () => {
    expect(linkedinKey('https://example.com/in/x')).toBeNull()
    expect(linkedinKey('https://www.linkedin.com/company/acme')).toBeNull()
    expect(linkedinKey('')).toBeNull()
    expect(linkedinKey(null)).toBeNull()
  })
})

describe('maskEmail', () => {
  it('keeps the first letter and the domain', () => {
    expect(maskEmail('pool@example.test')).toBe('p***@example.test')
    expect(maskEmail('Ana.Ilievska@Example.TEST')).toBe('a***@example.test')
  })
  it('is null without an @ after the first character', () => {
    expect(maskEmail('nope')).toBeNull()
    expect(maskEmail('@example.test')).toBeNull()
    expect(maskEmail(null)).toBeNull()
  })
})

describe('longDate', () => {
  it('prints day, month and year from a date', () => {
    expect(longDate('2026-10-12')).toBe('12 Oct 2026')
    expect(longDate('2025-01-03')).toBe('3 Jan 2025')
  })
  it('reads the UTC day of a timestamp', () => {
    expect(longDate('2026-10-12T23:30:00+00:00')).toBe('12 Oct 2026')
  })
})

const filters: PoolFilters = {
  q: 'ana',
  sourceKey: 'head_hunt',
  contact: 'wait',
  activity: '90d',
  companyId: 'c-1',
  showArchived: true,
}

describe('poolPayload', () => {
  it('sends the search_candidates keys with the page as an offset', () => {
    expect(poolPayload(filters, 0)).toEqual({
      q: 'ana',
      source_key: 'head_hunt',
      contact: 'wait',
      activity: '90d',
      company_id: 'c-1',
      include_archived: true,
      limit: POOL_PAGE_SIZE,
      offset: 0,
    })
    expect(poolPayload(filters, 2).offset).toBe(2 * POOL_PAGE_SIZE)
  })
  it('sends null for empty text filters', () => {
    const empty = poolPayload({ q: '  ', sourceKey: '', contact: 'any', activity: 'any', companyId: '', showArchived: false }, 0)
    expect(empty).toMatchObject({ q: null, source_key: null, company_id: null, include_archived: false })
  })
})

describe('poolQuery ↔ poolFiltersFromQuery', () => {
  it('round-trips every filter over q, source, contact, activity, company, archived', () => {
    const query = poolQuery(filters)
    expect(query).toEqual({ q: 'ana', source: 'head_hunt', contact: 'wait', activity: '90d', company: 'c-1', archived: '1' })
    expect(poolFiltersFromQuery(query)).toEqual(filters)
  })
  it('leaves default filters out of the address and reads them back as defaults', () => {
    const defaults: PoolFilters = { q: '', sourceKey: '', contact: 'any', activity: 'any', companyId: '', showArchived: false }
    expect(poolQuery(defaults)).toEqual({})
    expect(poolFiltersFromQuery({})).toEqual(defaults)
  })
  it('ignores unknown values and repeated keys', () => {
    const read = poolFiltersFromQuery({ contact: 'bogus', activity: ['1y', '90d'], archived: '0', q: null, tab: 'pool' })
    expect(read).toEqual({ q: '', sourceKey: '', contact: 'any', activity: '1y', companyId: '', showArchived: false })
  })
})

const TODAY = '2026-09-21'
const rule = (over: Partial<{ do_not_contact: boolean; contact_later: boolean; contact_again_after: string | null }>) => ({
  do_not_contact: false,
  contact_later: false,
  contact_again_after: null,
  ...over,
})

describe('contactState / contactBadge', () => {
  it('is ok with no rule', () => {
    expect(contactState(rule({}), TODAY)).toBe('ok')
    expect(contactBadge(rule({}), TODAY)).toBe('')
  })
  it('never wins over everything', () => {
    const c = rule({ do_not_contact: true, contact_later: true, contact_again_after: '2027-01-01' })
    expect(contactState(c, TODAY)).toBe('do_not_contact')
    expect(contactBadge(c, TODAY)).toBe('Do not contact')
  })
  it('waits without a date', () => {
    const c = rule({ contact_later: true })
    expect(contactState(c, TODAY)).toBe('wait')
    expect(contactBadge(c, TODAY)).toBe('Contact later')
  })
  it('waits until a future date and names it', () => {
    const c = rule({ contact_later: true, contact_again_after: '2026-10-12' })
    expect(contactState(c, TODAY)).toBe('wait')
    expect(contactBadge(c, TODAY)).toBe('Contact after 12 Oct 2026')
    expect(contactState(c, '2026-10-11')).toBe('wait')
  })
  it('is ok from the named day on, as assert_contactable lets it through', () => {
    const c = rule({ contact_later: true, contact_again_after: '2026-10-12' })
    expect(contactState(c, '2026-10-12')).toBe('ok')
    expect(contactBadge(c, '2026-10-12')).toBe('')
    expect(contactState(c, '2027-01-01')).toBe('ok')
  })
})

function match(over: Partial<CandidateMatch>): CandidateMatch {
  return {
    id: 'cand-1',
    full_name: 'Ana Ilievska',
    match: 'email',
    visible: true,
    attachable: true,
    do_not_contact: false,
    contact_later: false,
    contact_again_after: null,
    email: 'ana@example.test',
    phone: null,
    linkedin_url: null,
    current_title: null,
    current_employer: null,
    last_activity_at: null,
    applications: [],
    ...over,
  }
}

describe('matchSentence', () => {
  it('names the person and what matched', () => {
    expect(matchSentence(match({ match: 'email' }))).toBe('This looks like Ana Ilievska (same email).')
    expect(matchSentence(match({ match: 'phone' }))).toBe('This looks like Ana Ilievska (same phone).')
    expect(matchSentence(match({ match: 'linkedin' }))).toBe('This looks like Ana Ilievska (same LinkedIn profile).')
    expect(matchSentence(match({ match: 'name' }))).toBe(
      'This looks like Ana Ilievska (same name — check before attaching).',
    )
  })
})

describe('matchHistoryLine', () => {
  it('tells the newest visible application', () => {
    const m = match({
      applications: [
        { id: 'a-2', job_title: 'Frontend Developer', company_name: 'Snowball', stage_key: 'rejected', received_at: '2026-03-05T10:00:00+00:00' },
        { id: 'a-1', job_title: 'Designer', company_name: 'Acme', stage_key: 'hired', received_at: '2024-11-20T10:00:00+00:00' },
      ],
    })
    expect(matchHistoryLine(m)).toBe('Applied to Frontend Developer at Snowball — rejected, Mar 2026.')
  })
  it('says the person is in the pool when nothing visible was applied to', () => {
    expect(matchHistoryLine(match({ applications: [] }))).toBe('Already in the talent pool.')
  })
  it('hides everything but the fact for a record outside the viewer’s companies', () => {
    expect(matchHistoryLine(match({ visible: false, applications: [] }))).toBe(
      'Already in the talent pool — details are outside your companies.',
    )
  })
})

describe('contactLine', () => {
  it('is empty without a rule', () => {
    expect(contactLine(match({}))).toBe('')
    expect(contactLine(match({ contact_later: true }))).toBe('')
  })
  it('says never', () => {
    expect(contactLine(match({ do_not_contact: true }))).toBe('Asked not to be contacted.')
  })
  it('says after which day', () => {
    expect(contactLine(match({ contact_later: true, contact_again_after: '2026-10-12' }))).toBe(
      'Asked to be contacted after 12 Oct 2026.',
    )
  })
})

describe('constants', () => {
  it('carry the plan sentences verbatim', () => {
    expect(NOT_ATTACHABLE).toBe('In the pool, but you would need the same email, phone or LinkedIn to use this record.')
    expect(SOURCE_FALLBACK_LABEL).toBe('Added by hand')
    expect(POOL_PAGE_SIZE).toBe(50)
  })
})
