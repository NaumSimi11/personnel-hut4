import type { CsvRow, ZohoExport } from './csv.js'
import { splitList } from './csv.js'
import { longDate, parseEducationMonth, parseIsoDate, parseSqlDateTime, parseUsDate, parseUsDateTime, usDateToCalendar } from './dates.js'
import {
  UnknownValueError,
  mapDepartment,
  mapJobStatus,
  mapSource,
  mapStatus,
  notePrefix,
  rewriteMentions,
  staleRule,
  type JobStatus,
  type StageKey,
} from './mapping.js'

/**
 * The export → the `import_zoho_recruit` payload (plan 052 §3.1 "Columns →
 * fields", §3.3) and the review file. Pure: rows in, JSON out; every fact
 * Zoho held is kept verbatim under `custom.zoho`, and an unreadable date is a
 * problem in the review, never a guess.
 */

export type PayloadUser = { zoho_id: string; email: string; name: string }
export type PayloadJob = {
  zoho_id: string; display_id: string; company_code: string | null; title: string; description: string | null
  status: JobStatus; created_at: string | null; modified_at: string | null; date_closed: string | null
  custom: { zoho: Record<string, unknown> }
}
export type Education = {
  institute: string | null; major: string | null; degree: string | null
  from: string | null; to: string | null; current: boolean; zoho_row_id: string
}
export type CandidateCustom = { zoho: Record<string, unknown>; education: Education[]; links: Record<string, string> }
export type PayloadCandidate = {
  zoho_id: string; display_id: string; full_name: string; email: string | null; phone: string | null; linkedin_url: string | null
  source_key: string; current_title: string | null; current_employer: string | null; location: string | null; skills: string[]
  summary: string | null; referred_by: string | null; owner_zoho_id: string | null
  created_at: string | null; updated_at: string | null; last_activity_at: string | null
  do_not_contact: boolean; do_not_contact_reason: string | null; do_not_contact_at: string | null; do_not_contact_by_zoho_id: string | null
  contact_later: boolean; custom: CandidateCustom
}
export type PayloadApplication = {
  zoho_id: string; candidate_zoho_id: string; job_zoho_id: string; stage_key: StageKey; stale_closed: boolean
  close_date: string | null; close_date_assumed: boolean; zoho_status: string; zoho_stage: string
  withdrawn_reason: string | null; rejected_reason: string | null; received_at: string | null; modified_at: string | null
  modified_by_zoho_id: string | null; hired_date: string | null; hired_by_zoho_id: string | null
  custom: { zoho: { created_by: string | null } }
}
export type PayloadNote = {
  zoho_id: string; application_zoho_id: string; kind: string; body: string
  actor_zoho_id: string | null; actor_name: string | null; created_at: string | null
}
export type Payload = {
  exported_at: string; timezone_assumed: string
  users: PayloadUser[]; jobs: PayloadJob[]; candidates: PayloadCandidate[]; applications: PayloadApplication[]; notes: PayloadNote[]
}
export type Problem = { kind: 'candidate' | 'job' | 'application' | 'note'; ref: string; message: string }
export type ValueCount = { value: string; count: number }
type Brief = { zoho_id: string; display_id: string; full_name: string }
export type Review = {
  column_map: typeof COLUMN_MAP
  same_linkedin_by_key: string[][]
  same_linkedin_by_url: string[][]
  same_name_groups: { name_key: string; members: (Brief & { linkedin_key: string | null })[] }[]
  never_associated: (Brief & { status: string; source: string; created_at: string | null })[]
  stale_applications: { zoho_id: string; candidate_zoho_id: string; job_zoho_id: string; zoho_status: string; stage_key: StageKey; close_date: string | null; close_date_assumed: boolean }[]
  unknown_statuses: ValueCount[]
  unknown_sources: ValueCount[]
  hires: { application_zoho_id: string; candidate: Brief & { email: string | null; phone: string | null }; job: { zoho_id: string; title: string; company_code: string | null }; hired_date: string | null; hired_by: string | null }[]
  unresolved_departments: { department: string; jobs: number }[]
  synthesised_reasons: string[]
  problems: Problem[]
}
export type Counts = {
  candidates: number
  applications: Record<string, number>
  do_not_contact: number
  contact_later: number
  jobs: Record<string, number>
  unresolved_departments: number
  notes: { attached: number; without_application: number; skipped_modules: number }
  problems: number
}
export type BuildResult = { payload: Payload; review: Review; counts: Counts; unknown: { statuses: ValueCount[]; sources: ValueCount[] } }

export const COLUMN_MAP = {
  'zoho_id / display_id': 'Candidate Id (Zrecruit_…) / Candidate ID (ZR_…_CAND)',
  full_name: 'Full Name → First Name + Last Name → Last Name → display id',
  email: 'Email (malformed → custom.links.raw_email); Secondary Email → custom.links.secondary_email',
  phone: 'coalesce(Mobile, Phone) (never both; the other → custom.links)',
  linkedin_url: 'LinkedIn',
  'current_title / current_employer': 'Current Job Title / Current Employer',
  location: 'City, Country joined with ", "',
  skills: 'Skill Set split on "," and trimmed (an item over 60 characters → custom.zoho.skill_set only)',
  summary: 'Profile Summary, else Additional Info',
  referred_by: 'Referred by Employee',
  source_key: 'Source through the map',
  owner_zoho_id: 'Candidate Owner ID',
  'created_at / updated_at / last_activity_at': 'Created Time / Modified Time / Last Activity Time (fallback Modified Time)',
  'custom.zoho': 'id, display_id, status, stage, source, owner_name, created_by_name, rating, is_locked, fresh_candidate, experience_years, expected_salary / current_salary (only when > 0), tags',
  'custom.education[]': 'Candidates_Educational_Details.csv rows in file order: { institute, major, degree, from, to, current, zoho_row_id }; Mon-YYYY → YYYY-MM; a year below 1900 → null',
} as const

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/
const SKILL_MAX = 60
const SUMMARY_MAX = 4000
const REASON_MAX = 300
const REASON_WINDOW_MS = 7 * 24 * 60 * 60 * 1000
const REASON_NOTE_TYPES = new Set(['Change Status', 'Unassociation', 'Notes'])
const NEVER = 'NEVER to be contacted again'
const LATER = new Set(['Contact in Future', 'Rejected-Hirable'])
const SKIPPED_NOTE_MODULES = new Set(['Job Openings', 'Tasks'])

// ------------------------------------------------------------------ keys
// Mirrors of app.phone_key / app.name_key / app.linkedin_key (0067), for the
// review file's groups. Suggestion keys, never identities.

export function phoneKey(phone: string | null): string | null {
  const digits = (phone ?? '').replace(/[^0-9]/g, '')
  return digits.length >= 8 ? digits.slice(-8) : null
}

const FOLD: Readonly<Record<string, string>> = { ð: 'd', đ: 'd', ø: 'o', ł: 'l', ı: 'i' }

export function nameKey(name: string | null): string | null {
  if (!name) return null
  const folded = name
    .normalize('NFC')
    .toLowerCase()
    .replace(/\([^)]*\)|\[[^\]]*\]/g, ' ')
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .replace(/[ðđøłı]/g, (ch) => FOLD[ch])
  const words = folded.split(/[^\p{L}]+/u).filter((w) => w !== '')
  return words.length ? words.sort().join(' ') : null
}

export function linkedinKey(url: string | null): string | null {
  const m = /linkedin\.com\/in\/([^/?#\s]+)/.exec((url ?? '').toLowerCase())
  return m ? m[1] : null
}

// ------------------------------------------------------------ candidates

const blank = (v: string | null | undefined): string | null => {
  const t = (v ?? '').trim()
  return t === '' ? null : t
}
const num = (v: string | undefined): number | null => {
  const t = (v ?? '').trim()
  if (t === '') return null
  const n = Number(t)
  return Number.isFinite(n) ? n : null
}
const positive = (v: string | undefined): number | null => {
  const n = num(v)
  return n !== null && n > 0 ? n : null
}
const bool = (v: string | undefined): boolean => (v ?? '').trim().toLowerCase() === 'true'

export function candidateName(r: CsvRow): string {
  const full = blank(r['Full Name'])
  if (full) return full
  const parts = [blank(r['First Name']), blank(r['Last Name'])].filter((p): p is string => p !== null)
  return parts.length ? parts.join(' ') : r['Candidate ID'].trim()
}

export function candidateEmail(r: CsvRow): { email: string | null; links: Record<string, string> } {
  const links: Record<string, string> = {}
  const raw = blank(r.Email)
  const email = raw && EMAIL.test(raw) ? raw.toLowerCase() : null
  if (raw && !email) links.raw_email = raw
  const secondary = blank(r['Secondary Email'])
  if (secondary) links.secondary_email = secondary
  return { email, links }
}

export function candidatePhone(r: CsvRow): { phone: string | null; links: Record<string, string> } {
  const mobile = blank(r.Mobile)
  const phone = blank(r.Phone)
  if (mobile) return { phone: mobile, links: phone ? { phone } : {} }
  return { phone, links: {} }
}

export function candidateSkills(value: string): { skills: string[]; dropped: string[] } {
  const items = splitList(value)
  return { skills: items.filter((s) => s.length <= SKILL_MAX), dropped: items.filter((s) => s.length > SKILL_MAX) }
}

export function educationOf(rows: CsvRow[]): Education[] {
  return rows.map((r) => ({
    institute: blank(r['Institute / School']),
    major: blank(r['Major / Department']),
    degree: blank(r.Degree),
    from: parseEducationMonth(r.Duration_From ?? ''),
    to: parseEducationMonth(r.Duration_To ?? ''),
    current: (r['Currently pursuing'] ?? '').trim() === '1',
    zoho_row_id: r.TABULARROWID,
  }))
}

export type ContactInput = { candidate: CsvRow; associations: CsvRow[]; notes: CsvRow[]; users: ReadonlyMap<string, string>; tz: string }
export type ContactFlags = {
  do_not_contact: boolean; do_not_contact_reason: string | null; do_not_contact_at: string | null
  do_not_contact_by_zoho_id: string | null; contact_later: boolean; reason_synthesised: boolean
}

const NO_FLAGS: ContactFlags = {
  do_not_contact: false, do_not_contact_reason: null, do_not_contact_at: null, do_not_contact_by_zoho_id: null, contact_later: false, reason_synthesised: false,
}

/** The latest Change Status / Unassociation / Notes body within 7 days of the stamp, cut at 300 characters. */
function nearbyReason(notes: CsvRow[], at: string | null, users: ReadonlyMap<string, string>, tz: string): string | null {
  if (!at) return null
  const stamp = Date.parse(at)
  const candidates = notes
    .filter((n) => REASON_NOTE_TYPES.has(n['Note Type']))
    .map((n) => ({ body: rewriteMentions((n['Note Content'] ?? '').trim(), users), created: parseUsDateTime(n['Created Time'] ?? '', tz) }))
    .filter((n) => n.body !== '' && n.created !== null && Math.abs(Date.parse(n.created) - stamp) <= REASON_WINDOW_MS)
    .sort((a, b) => Date.parse(b.created as string) - Date.parse(a.created as string))
  return candidates.length ? candidates[0].body.slice(0, REASON_MAX) : null
}

/**
 * The contact rule (plan 052 §3.1 "Contact flags"): never = candidate-level ∪
 * association-level NEVER, stamped by the latest NEVER association (else the
 * candidate row); later from association statuses only; never wins.
 */
export function contactFlags({ candidate, associations, notes, users, tz }: ContactInput): ContactFlags {
  const nevers = associations
    .filter((a) => a['Candidate Status'] === NEVER)
    .map((a) => ({ at: parseSqlDateTime(a['Modified Time'] ?? '', tz), by: blank(a['Modified By']) }))
    .sort((a, b) => Date.parse(b.at ?? '0') - Date.parse(a.at ?? '0'))
  const never = nevers.length > 0 || candidate['Candidate Status'] === NEVER
  if (!never) {
    return { ...NO_FLAGS, contact_later: associations.some((a) => LATER.has(a['Candidate Status'])) }
  }
  const stamp = nevers[0] ?? { at: parseUsDateTime(candidate['Modified Time'] ?? '', tz), by: blank(candidate['Modified By']) }
  const found = nearbyReason(notes, stamp.at, users, tz)
  const byName = (stamp.by && users.get(stamp.by)) || 'an unknown user'
  const synthesised = `Zoho Recruit: NEVER to be contacted again (set by ${byName} on ${stamp.at ? longDate(stamp.at, tz) : 'an unknown date'})`
  return {
    do_not_contact: true,
    do_not_contact_reason: found ?? synthesised,
    do_not_contact_at: stamp.at,
    do_not_contact_by_zoho_id: stamp.by,
    contact_later: false,
    reason_synthesised: found === null,
  }
}

// ---------------------------------------------------------------- build

type Ctx = { tz: string; users: Map<string, string>; userEmail: Map<string, string>; problems: Problem[] }

function stamp(ctx: Ctx, kind: Problem['kind'], ref: string, column: string, value: string | undefined, parse: (v: string) => string | null): string | null {
  const raw = (value ?? '').trim()
  if (raw === '') return null
  const parsed = parse(raw)
  if (parsed === null) ctx.problems.push({ kind, ref, message: `${column} "${raw}" is not a date` })
  return parsed
}

function buildUsers(exp: ZohoExport): PayloadUser[] {
  return exp.users.map((u) => ({
    zoho_id: u['User ID'],
    email: u.Email.trim().toLowerCase(),
    name: [blank(u['First Name']), blank(u['Last Name'])].filter((p) => p).join(' ') || u.Email.trim().toLowerCase(),
  }))
}

function buildJob(j: CsvRow, departments: Map<string, string>, ctx: Ctx): PayloadJob {
  const ref = j['Job Opening Id']
  const department = departments.get(j['Department ID']) ?? ''
  const status = mapJobStatus(j['Job Opening Status'])
  const dateClosed = stamp(ctx, 'job', ref, 'Date Closed', j['Date Closed'], (v) => parseUsDate(v, ctx.tz))
  return {
    zoho_id: ref,
    display_id: j['Job Opening ID'],
    company_code: mapDepartment(department) ?? null,
    title: blank(j['Posting Title']) ?? blank(j.Title) ?? '',
    description: blank(j['Job Description']),
    status,
    created_at: stamp(ctx, 'job', ref, 'Created Time', j['Created Time'], (v) => parseUsDateTime(v, ctx.tz)),
    modified_at: stamp(ctx, 'job', ref, 'Modified Time', j['Modified Time'], (v) => parseUsDateTime(v, ctx.tz)),
    date_closed: dateClosed,
    custom: {
      zoho: {
        id: ref,
        display_id: j['Job Opening ID'],
        department,
        hiring_manager_email: ctx.userEmail.get(j['Hiring Manager Id']) ?? null,
        recruiters: splitList(j['Assigned Recruiter(s)'] ?? '', ';').map((id) => ctx.users.get(id) ?? id),
        target_date: usDateToCalendar(j['Target Date'] ?? ''),
        date_opened: usDateToCalendar(j['Date Opened'] ?? ''),
        date_closed: usDateToCalendar(j['Date Closed'] ?? ''),
        headcount: num(j['Number of Positions']),
        close_date_assumed: (status === 'filled' || status === 'closed') && dateClosed === null,
      },
    },
  }
}

function buildCandidate(r: CsvRow, education: CsvRow[], flags: ContactFlags, ctx: Ctx): PayloadCandidate {
  const ref = r['Candidate Id']
  const { email, links: emailLinks } = candidateEmail(r)
  const { phone, links: phoneLinks } = candidatePhone(r)
  const { skills, dropped } = candidateSkills(r['Skill Set'] ?? '')
  const location = [blank(r.City), blank(r.Country)].filter((p) => p).join(', ') || null
  const summary = blank(r['Profile Summary']) ?? blank(r['Additional Info'])
  const updatedAt = stamp(ctx, 'candidate', ref, 'Modified Time', r['Modified Time'], (v) => parseUsDateTime(v, ctx.tz))
  const zoho: Record<string, unknown> = {
    id: ref,
    display_id: r['Candidate ID'],
    status: r['Candidate Status'],
    stage: r['Candidate Stage'],
    source: r.Source,
    owner_name: ctx.users.get(r['Candidate Owner ID']) ?? null,
    created_by_name: ctx.users.get(r['Created By']) ?? null,
    rating: num(r.Rating),
    is_locked: bool(r['Is Locked']),
    fresh_candidate: bool(r['Fresh Candidate']),
    experience_years: num(r['Experience in Years']),
    ...(positive(r['Expected Salary']) !== null ? { expected_salary: positive(r['Expected Salary']) } : {}),
    ...(positive(r['Current Salary']) !== null ? { current_salary: positive(r['Current Salary']) } : {}),
    tags: splitList(r['Associated Tags'] ?? ''),
    ...(dropped.length ? { skill_set: r['Skill Set'] } : {}),
  }
  return {
    zoho_id: ref,
    display_id: r['Candidate ID'],
    full_name: candidateName(r).normalize('NFC'),
    email,
    phone,
    linkedin_url: blank(r.LinkedIn),
    source_key: mapSource(r.Source.trim()),
    current_title: blank(r['Current Job Title']),
    current_employer: blank(r['Current Employer']),
    location,
    skills,
    summary: summary ? summary.slice(0, SUMMARY_MAX) : null,
    referred_by: blank(r['Referred by Employee']),
    owner_zoho_id: blank(r['Candidate Owner ID']),
    created_at: stamp(ctx, 'candidate', ref, 'Created Time', r['Created Time'], (v) => parseUsDateTime(v, ctx.tz)),
    updated_at: updatedAt,
    last_activity_at: stamp(ctx, 'candidate', ref, 'Last Activity Time', r['Last Activity Time'], (v) => parseUsDateTime(v, ctx.tz)) ?? updatedAt,
    do_not_contact: flags.do_not_contact,
    do_not_contact_reason: flags.do_not_contact_reason,
    do_not_contact_at: flags.do_not_contact_at,
    do_not_contact_by_zoho_id: flags.do_not_contact_by_zoho_id,
    contact_later: flags.contact_later,
    custom: { zoho, education: educationOf(education), links: { ...emailLinks, ...phoneLinks } },
  }
}

function buildApplication(a: CsvRow, job: PayloadJob, ctx: Ctx): PayloadApplication {
  const ref = a['Associated Id']
  const mapped = mapStatus(a['Candidate Status'])
  const stale = staleRule(mapped.stage, { status: jobStatusName(job.status), dateClosed: job.date_closed, modifiedAt: job.modified_at })
  return {
    zoho_id: ref,
    candidate_zoho_id: a['Candidate ID'],
    job_zoho_id: a['Job Opening ID'],
    stage_key: mapped.stage,
    stale_closed: stale.stale_closed,
    close_date: stale.stale_closed ? stale.close_date : null,
    close_date_assumed: stale.stale_closed ? stale.close_date_assumed : false,
    zoho_status: a['Candidate Status'],
    zoho_stage: a.Stage,
    withdrawn_reason: stale.stale_closed ? stale.withdrawn_reason : mapped.stage === 'withdrawn' ? (mapped.reason ?? null) : null,
    rejected_reason: mapped.stage === 'rejected' ? (mapped.reason ?? null) : null,
    received_at: stamp(ctx, 'application', ref, 'Created Time', a['Created Time'], (v) => parseSqlDateTime(v, ctx.tz)),
    modified_at: stamp(ctx, 'application', ref, 'Modified Time', a['Modified Time'], (v) => parseSqlDateTime(v, ctx.tz)),
    modified_by_zoho_id: blank(a['Modified By']),
    hired_date: stamp(ctx, 'application', ref, 'Hired Date', a['Hired Date'], parseIsoDate),
    hired_by_zoho_id: blank(a['Hired By']),
    custom: { zoho: { created_by: ctx.users.get(a['Created By']) ?? null } },
  }
}

/** The Zoho name of a mapped job status, for the stale rule. */
function jobStatusName(status: JobStatus): string {
  return { filled: 'Filled', closed: 'Cancelled', open: 'In-progress', on_hold: 'Inactive' }[status]
}

type NoteOutcome = { note: PayloadNote } | { left: 'without_application' | 'skipped_modules' }

function buildNote(n: CsvRow, pairs: Map<string, string>, interviews: Map<string, string>, ctx: Ctx): NoteOutcome {
  if (SKIPPED_NOTE_MODULES.has(n.Module)) return { left: 'skipped_modules' }
  const own = n['Candidate Id'] && n['Job Opening Id'] ? `${n['Candidate Id']}|${n['Job Opening Id']}` : null
  const viaInterview = n.Module === 'Interviews' ? (interviews.get(n['Parent ID']) ?? interviews.get(n['Interview Id'] ?? '')) : undefined
  const applicationId = (own && pairs.get(own)) ?? (viaInterview && pairs.get(viaInterview)) ?? null
  if (!applicationId) return { left: 'without_application' }
  const createdAt = stamp(ctx, 'note', n['Note Id'], 'Created Time', n['Created Time'], (v) => parseUsDateTime(v, ctx.tz))
  const actorId = blank(n['Created By'])
  const actorName = (actorId && ctx.users.get(actorId)) ?? null
  const kind = n['Note Type'] || 'Notes'
  // An undated note goes through unprefixed: import_zoho_recruit builds the prefix itself then.
  const prefix = createdAt ? `${notePrefix(kind, createdAt, actorName ?? 'Zoho Recruit', ctx.tz)} ` : ''
  return {
    note: {
      zoho_id: n['Note Id'],
      application_zoho_id: applicationId,
      kind,
      body: `${prefix}${rewriteMentions((n['Note Content'] ?? '').trim(), ctx.users)}`,
      actor_zoho_id: actorId,
      actor_name: actorName,
      created_at: createdAt,
    },
  }
}

function countValues(values: string[]): ValueCount[] {
  const counts = new Map<string, number>()
  for (const v of values) counts.set(v, (counts.get(v) ?? 0) + 1)
  return [...counts].map(([value, count]) => ({ value, count })).sort((a, b) => a.value.localeCompare(b.value))
}

function unknownValues(values: string[], probe: (v: string) => unknown): ValueCount[] {
  const unknown = values.filter((v) => {
    try {
      probe(v)
      return false
    } catch (e) {
      if (e instanceof UnknownValueError) return true
      throw e
    }
  })
  return countValues(unknown)
}

function groupBy<T>(items: T[], key: (t: T) => string | null): Map<string, T[]> {
  const groups = new Map<string, T[]>()
  for (const item of items) {
    const k = key(item)
    if (k === null) continue
    groups.set(k, [...(groups.get(k) ?? []), item])
  }
  return groups
}

function byCandidate(rows: CsvRow[], column: string): Map<string, CsvRow[]> {
  return groupBy(rows, (r) => blank(r[column]))
}

export function buildPayload(exp: ZohoExport, opts: { tz: string; exportedAt: string }): BuildResult {
  const users = buildUsers(exp)
  const ctx: Ctx = {
    tz: opts.tz,
    users: new Map(users.map((u) => [u.zoho_id, u.name])),
    userEmail: new Map(users.map((u) => [u.zoho_id, u.email])),
    problems: [],
  }
  const unknown = {
    statuses: unknownValues(exp.associations.map((a) => a['Candidate Status']), mapStatus),
    sources: unknownValues(exp.candidates.map((c) => c.Source.trim()), mapSource),
  }
  const unknownStatus = new Set(unknown.statuses.map((u) => u.value))
  const unknownSource = new Set(unknown.sources.map((u) => u.value))

  const departments = new Map(exp.departments.map((d) => [d['Department Id'], d['Department Name']]))
  const jobs = exp.jobs.map((j) => buildJob(j, departments, ctx))
  const jobById = new Map(jobs.map((j) => [j.zoho_id, j]))
  const unresolvedDepartments = [...groupBy(jobs, (j) => (mapDepartment(String(j.custom.zoho.department)) === undefined ? String(j.custom.zoho.department) : null))]
    .map(([department, rows]) => ({ department, jobs: rows.length }))

  const associationsByCandidate = byCandidate(exp.associations, 'Candidate ID')
  const notesByCandidate = new Map<string, CsvRow[]>()
  for (const n of exp.notes) {
    for (const id of new Set([blank(n['Parent ID']), blank(n['Candidate Id'])])) {
      if (id) notesByCandidate.set(id, [...(notesByCandidate.get(id) ?? []), n])
    }
  }
  const educationByCandidate = byCandidate(exp.education, 'Candidate Id')
  const candidates = exp.candidates
    .filter((c) => !unknownSource.has(c.Source.trim()))
    .map((c) => {
      const flags = contactFlags({
        candidate: c,
        associations: associationsByCandidate.get(c['Candidate Id']) ?? [],
        notes: notesByCandidate.get(c['Candidate Id']) ?? [],
        users: ctx.users,
        tz: ctx.tz,
      })
      return { row: buildCandidate(c, educationByCandidate.get(c['Candidate Id']) ?? [], flags, ctx), flags }
    })

  // An association to a job the export does not carry is a problem, never a
  // guess: reported like a date that cannot be read, and the row stays out.
  const applications = exp.associations
    .filter((a) => !unknownStatus.has(a['Candidate Status']))
    .flatMap((a) => {
      const job = jobById.get(a['Job Opening ID'])
      if (job) return [buildApplication(a, job, ctx)]
      ctx.problems.push({ kind: 'application', ref: a['Associated Id'], message: `Job Opening ID "${a['Job Opening ID']}" is not in the jobs export` })
      return []
    })
  const pairs = new Map(applications.map((a) => [`${a.candidate_zoho_id}|${a.job_zoho_id}`, a.zoho_id]))
  const interviews = new Map(exp.interviews.map((i) => [i['Interview Id'], `${i['Candidate ID']}|${i['Job Opening ID']}`]))
  const noteCounts = { attached: 0, without_application: 0, skipped_modules: 0 }
  const notes: PayloadNote[] = []
  for (const n of exp.notes) {
    const outcome = buildNote(n, pairs, interviews, ctx)
    if ('note' in outcome) {
      notes.push(outcome.note)
      noteCounts.attached += 1
    } else {
      noteCounts[outcome.left] += 1
    }
  }

  const candidateRows = candidates.map((c) => c.row)
  const brief = (c: PayloadCandidate): Brief => ({ zoho_id: c.zoho_id, display_id: c.display_id, full_name: c.full_name })
  const groups = (key: (c: PayloadCandidate) => string | null): string[][] =>
    [...groupBy(candidateRows, key).values()].filter((g) => g.length > 1).map((g) => g.map((c) => c.zoho_id))
  const associated = new Set(exp.associations.map((a) => a['Candidate ID']))
  const applicationCounts: Record<string, number> = {}
  for (const a of applications) applicationCounts[a.stage_key] = (applicationCounts[a.stage_key] ?? 0) + 1
  const stale = applications.filter((a) => a.stale_closed)
  const jobCounts: Record<string, number> = {}
  for (const j of jobs) {
    const code = j.company_code ?? '(none)'
    jobCounts[code] = (jobCounts[code] ?? 0) + 1
  }
  const candidateById = new Map(candidateRows.map((c) => [c.zoho_id, c]))

  const review: Review = {
    column_map: COLUMN_MAP,
    same_linkedin_by_key: groups((c) => linkedinKey(c.linkedin_url)),
    same_linkedin_by_url: groups((c) => blank(c.linkedin_url)),
    same_name_groups: [...groupBy(candidateRows, (c) => nameKey(c.full_name))]
      .filter(([, g]) => g.length > 1)
      .map(([name_key, g]) => ({ name_key, members: g.map((c) => ({ ...brief(c), linkedin_key: linkedinKey(c.linkedin_url) })) })),
    never_associated: candidateRows
      .filter((c) => !associated.has(c.zoho_id))
      .map((c) => ({ ...brief(c), status: String(c.custom.zoho.status), source: String(c.custom.zoho.source), created_at: c.created_at })),
    stale_applications: stale.map((a) => ({
      zoho_id: a.zoho_id, candidate_zoho_id: a.candidate_zoho_id, job_zoho_id: a.job_zoho_id, zoho_status: a.zoho_status,
      stage_key: a.stage_key, close_date: a.close_date, close_date_assumed: a.close_date_assumed,
    })),
    unknown_statuses: unknown.statuses,
    unknown_sources: unknown.sources,
    hires: applications
      .filter((a) => a.stage_key === 'hired')
      .map((a) => {
        const c = candidateById.get(a.candidate_zoho_id)
        const j = jobById.get(a.job_zoho_id) as PayloadJob
        return {
          application_zoho_id: a.zoho_id,
          candidate: c ? { ...brief(c), email: c.email, phone: c.phone } : { zoho_id: a.candidate_zoho_id, display_id: '', full_name: '', email: null, phone: null },
          job: { zoho_id: j.zoho_id, title: j.title, company_code: j.company_code },
          hired_date: a.hired_date,
          hired_by: (a.hired_by_zoho_id && ctx.users.get(a.hired_by_zoho_id)) ?? null,
        }
      }),
    unresolved_departments: unresolvedDepartments,
    synthesised_reasons: candidates.filter((c) => c.flags.reason_synthesised).map((c) => c.row.zoho_id),
    problems: ctx.problems,
  }
  const counts: Counts = {
    candidates: candidateRows.length,
    applications: { ...applicationCounts, stale: stale.length },
    do_not_contact: candidateRows.filter((c) => c.do_not_contact).length,
    contact_later: candidateRows.filter((c) => c.contact_later).length,
    jobs: jobCounts,
    unresolved_departments: unresolvedDepartments.length,
    notes: noteCounts,
    problems: ctx.problems.length,
  }
  const payload: Payload = {
    exported_at: opts.exportedAt,
    timezone_assumed: opts.tz,
    users,
    jobs,
    candidates: candidateRows,
    applications,
    notes,
  }
  return { payload, review, counts, unknown }
}
