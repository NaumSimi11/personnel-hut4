import type { LocationQuery } from 'vue-router'

/**
 * Pure logic for the talent pool (plan 052): the browser mirrors of the SQL
 * key helpers (app.phone_key / name_key / linkedin_key / mask_email in
 * migration 0067 — the smoke fixtures are shared with candidatePool.test.ts),
 * the search filters and their address-bar form, the contact rule as the UI
 * shows it, and the sentences of the "Is this the same person?" hint. The
 * database decides everything (search_candidates, upsert_sourced_candidate,
 * assert_contactable); this file only phrases it.
 */

// ---------------------------------------------------------------- key mirrors

/** The last eight digits when at least eight are present; never written back. */
export function phoneKey(phone: string | null | undefined): string | null {
  const digits = (phone ?? '').replace(/[^0-9]/g, '')
  return digits.length >= 8 ? digits.slice(-8) : null
}

// The exact translate table of app.name_key, so a name keys the same here
// and in the stored generated column. Cyrillic is deliberately not folded.
const FOLD_FROM = 'àáâãäåāăąçćčďđðèéêëēėęěìíîïīįıłñńňòóôõöøōőŕřśšşșțťùúûüūůűųýÿžźż'
const FOLD_TO = 'aaaaaaaaacccdddeeeeeeeeiiiiiiilnnnoooooooorrssssttuuuuuuuuyyzzz'
const FOLD = new Map(Array.from(FOLD_FROM, (ch, i) => [ch, FOLD_TO[i] ?? ch]))

/**
 * Lower-cased, Latin diacritics folded, bracketed parts dropped, non-letters
 * to spaces, words sorted and joined. A suggestion key, never an identity.
 */
export function nameKey(name: string | null | undefined): string | null {
  if (!name) return null
  const folded = Array.from(name.replace(/\([^)]*\)|\[[^\]]*\]/g, ' ').toLowerCase(), (ch) => FOLD.get(ch) ?? ch).join('')
  const words = folded
    .replace(/[^\p{L}]+/gu, ' ')
    .trim()
    .split(' ')
    .filter((w) => w !== '')
    .sort()
  return words.length ? words.join(' ') : null
}

/** The /in/ slug of a linkedin.com address, lower-cased; null for anything else. */
export function linkedinKey(url: string | null | undefined): string | null {
  const slug = (url ?? '').toLowerCase().match(/linkedin\.com\/in\/([^/?#\s]+)/)?.[1]
  return slug || null
}

/** p***@example.test; null without an @ after the first character. */
export function maskEmail(email: string | null | undefined): string | null {
  if (!email) return null
  const at = email.indexOf('@')
  if (at < 1) return null
  return `${email[0]}***@${email.slice(at + 1).split('@')[0]}`.toLowerCase()
}

// ------------------------------------------------------------------- dates

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

function utcDate(iso: string): Date {
  return new Date(iso.length === 10 ? `${iso}T00:00:00Z` : iso)
}

/** "2026-10-12" → "12 Oct 2026" (shortDate in lib/leave.ts has no year). */
export function longDate(iso: string): string {
  const d = utcDate(iso)
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`
}

/** "2026-10-12T…" → "Oct 2026". */
function monthYear(iso: string): string {
  const d = utcDate(iso)
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`
}

// ---------------------------------------------------------------- the search

export const POOL_PAGE_SIZE = 50
export const SOURCE_FALLBACK_LABEL = 'Added by hand'

export const CONTACT_FILTERS = ['any', 'ok', 'do_not_contact', 'wait'] as const
export const ACTIVITY_FILTERS = ['any', '90d', '1y', 'older'] as const
export type ContactFilter = (typeof CONTACT_FILTERS)[number]
export type ActivityFilter = (typeof ACTIVITY_FILTERS)[number]

/** One application of the search row, from the viewer's companies only. */
export type PoolApplication = {
  id: string
  job_id: string
  job_title: string
  company_id: string
  company_name: string
  stage_key: string
  received_at: string
}

/** One row of search_candidates. */
export type PoolRow = {
  id: string
  full_name: string
  email: string | null
  phone: string | null
  current_title: string | null
  current_employer: string | null
  location: string | null
  skills: string[]
  source_key: string
  source_label: string | null
  provider: string
  do_not_contact: boolean
  contact_later: boolean
  contact_again_after: string | null
  last_activity_at: string
  archived_at: string | null
  files_count: number
  /** Every application the viewer may see; `applications` is the latest three of them. */
  applications_count: number
  applications: PoolApplication[]
}

export type PoolFilters = {
  q: string
  sourceKey: string
  contact: ContactFilter
  activity: ActivityFilter
  companyId: string
  showArchived: boolean
}

export const EMPTY_POOL_FILTERS: PoolFilters = {
  q: '',
  sourceKey: '',
  contact: 'any',
  activity: 'any',
  companyId: '',
  showArchived: false,
}

/** The search_candidates payload for page `page` (0-based, POOL_PAGE_SIZE a page). */
export function poolPayload(filters: PoolFilters, page: number) {
  return {
    q: filters.q.trim() || null,
    source_key: filters.sourceKey || null,
    contact: filters.contact,
    activity: filters.activity,
    company_id: filters.companyId || null,
    include_archived: filters.showArchived,
    limit: POOL_PAGE_SIZE,
    offset: Math.max(0, page) * POOL_PAGE_SIZE,
  }
}

/** The filters as route.query keys; defaults stay out so the address stays short. */
export function poolQuery(filters: PoolFilters): Record<string, string> {
  return {
    ...(filters.q && { q: filters.q }),
    ...(filters.sourceKey && { source: filters.sourceKey }),
    ...(filters.contact !== 'any' && { contact: filters.contact }),
    ...(filters.activity !== 'any' && { activity: filters.activity }),
    ...(filters.companyId && { company: filters.companyId }),
    ...(filters.showArchived && { archived: '1' }),
  }
}

function queryString(query: LocationQuery, key: string): string {
  const raw = query[key]
  const value = Array.isArray(raw) ? raw[0] : raw
  return typeof value === 'string' ? value : ''
}

function oneOf<T extends string>(value: string, allowed: readonly T[], fallback: T): T {
  return (allowed as readonly string[]).includes(value) ? (value as T) : fallback
}

/** The inverse of poolQuery; unknown values fall back to the defaults. */
export function poolFiltersFromQuery(query: LocationQuery): PoolFilters {
  return {
    q: queryString(query, 'q'),
    sourceKey: queryString(query, 'source'),
    contact: oneOf(queryString(query, 'contact'), CONTACT_FILTERS, 'any'),
    activity: oneOf(queryString(query, 'activity'), ACTIVITY_FILTERS, 'any'),
    companyId: queryString(query, 'company'),
    showArchived: queryString(query, 'archived') === '1',
  }
}

// ------------------------------------------------------------ the contact rule

export type ContactRule = {
  do_not_contact: boolean
  contact_later: boolean
  contact_again_after: string | null
}

export type ContactState = 'ok' | 'do_not_contact' | 'wait'

/**
 * Never wins; a wait holds while its date is ahead of `today` (a date-only
 * wait holds until the rule is changed). From the named day on the person
 * may be contacted again, exactly as assert_contactable judges it.
 */
export function contactState(c: ContactRule, today: string): ContactState {
  if (c.do_not_contact) return 'do_not_contact'
  if (!c.contact_later) return 'ok'
  if (c.contact_again_after && c.contact_again_after <= today) return 'ok'
  return 'wait'
}

export function contactBadge(c: ContactRule, today: string): string {
  switch (contactState(c, today)) {
    case 'do_not_contact':
      return 'Do not contact'
    case 'wait':
      return c.contact_again_after ? `Contact after ${longDate(c.contact_again_after)}` : 'Contact later'
    default:
      return ''
  }
}

// ----------------------------------------------------------------- the hint

/** app.candidate_match_hint (0067): what a picker may learn about a match. */
export type CandidateMatch = {
  id: string
  full_name: string
  match: 'email' | 'phone' | 'linkedin' | 'name'
  visible: boolean
  attachable: boolean
  do_not_contact: boolean
  contact_later: boolean
  contact_again_after: string | null
  email: string | null
  phone: string | null
  linkedin_url: string | null
  current_title: string | null
  current_employer: string | null
  last_activity_at: string | null
  applications: {
    id: string
    job_title: string
    company_name: string
    stage_key: string
    received_at: string
  }[]
}

export const NOT_ATTACHABLE = 'In the pool, but you would need the same email, phone or LinkedIn to use this record.'

const MATCH_REASON: Record<CandidateMatch['match'], string> = {
  email: 'same email',
  phone: 'same phone',
  linkedin: 'same LinkedIn profile',
  name: 'same name — check before attaching',
}

export function matchSentence(m: CandidateMatch): string {
  return `This looks like ${m.full_name} (${MATCH_REASON[m.match]}).`
}

/** The newest visible application, or the fact of the record. */
export function matchHistoryLine(m: CandidateMatch): string {
  if (!m.visible) return 'Already in the talent pool — details are outside your companies.'
  const newest = [...m.applications].sort((a, b) => b.received_at.localeCompare(a.received_at))[0]
  if (!newest) return 'Already in the talent pool.'
  return `Applied to ${newest.job_title} at ${newest.company_name} — ${newest.stage_key}, ${monthYear(newest.received_at)}.`
}

export function contactLine(m: ContactRule): string {
  if (m.do_not_contact) return 'Asked not to be contacted.'
  if (m.contact_later && m.contact_again_after) return `Asked to be contacted after ${longDate(m.contact_again_after)}.`
  return ''
}
