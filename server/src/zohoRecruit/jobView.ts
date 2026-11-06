import type { CsvRow } from './csv.js'
import { candidateEmail, candidatePhone, candidateSkills } from './payload.js'
import { parseLocalMinute } from './dates.js'
import { mapSource, UnknownValueError } from './mapping.js'
import { ZOHO_STATUS_KEY } from './jobViewStatuses.js'

/**
 * HR's Zoho Recruit "Candidate-Job View" CSV -> the import payload (spec
 * 2026-11-05). One row per candidate-and-job; every stamp is a local
 * `YYYY-MM-DD HH:MM`. A value the vocabulary doesn't know is a problem,
 * never a guess. Pure: no I/O.
 */

export type ContactRule = { rule: 'do_not_contact' | 'contact_later'; reason: string }
export type JobViewCandidate = {
  zoho_id: string; full_name: string; email: string | null; phone: string | null; linkedin_url: string | null
  skills: string[]; source_key: string; owner_name: string | null; last_activity_at: string | null
  contact_rule: ContactRule | null; custom: { zoho: Record<string, string> }
}
export type JobViewApplication = {
  candidate_zoho_id: string; job_display_id: string; sub_status_key: string; received_at: string | null
  status_at: string | null; hired_date: string | null; owner_name: string | null; custom: { zoho: Record<string, string> }
}
export type JobViewNote = {
  candidate_zoho_id: string; job_display_id: string; seq: number; occurred_at: string | null
  kind_label: string; author_name: string; body: string
}
export type JobViewPayload = { candidates: JobViewCandidate[]; applications: JobViewApplication[]; notes: JobViewNote[] }
export type JobViewProblem = { ref: string; message: string }
export type JobViewResult = {
  payload: JobViewPayload
  counts: { candidates: number; applications: number; notes: number; byStatus: Record<string, number> }
  problems: JobViewProblem[]
}
export type ParsedNote = Omit<JobViewNote, 'candidate_zoho_id' | 'job_display_id' | 'seq'>

const COL = {
  candidateId: 'Candidate ID',
  jobId: 'Job Opening ID',
  // Zoho's own status. The lower-case "Status for this job" beside it is ignored.
  status: 'Status for this Job',
  ignored: 'Status for this job',
  notesLog: 'Job Notes Log (newest first)',
} as const

/** Candidate-level columns come first in the view; the job-level ones start at Job Opening ID. */
const JOB_COLUMNS_FROM = COL.jobId

const NOTE_HEADER = /^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\] (.+?) – (.+?):(?:\r?\n|$)([\s\S]*)$/
/** A blank line only ends an entry when the next line opens a new header; bodies may hold blank lines. */
const ENTRY_BREAK = /\r?\n[ \t]*\r?\n(?=\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\] )/

const cell = (r: CsvRow, column: string): string => (r[column] ?? '').trim()
const blank = (value: string): string | null => (value === '' ? null : value)
/** Zoho lists several recruiters in one cell ("; " or ", "); the first one owns the application. */
const firstName = (value: string): string | null => blank(value.split(/[;,]/).map((n) => n.trim()).find((n) => n !== '') ?? '')

/** The notes log of one application: entries split on blank lines, newest first. */
export function splitNotesLog(log: string, tz: string): ParsedNote[] {
  return log
    .split(ENTRY_BREAK)
    .map((chunk) => chunk.trim())
    .filter((chunk) => chunk !== '')
    .map((chunk) => {
      const m = NOTE_HEADER.exec(chunk)
      if (!m) return { occurred_at: null, kind_label: '', author_name: '', body: chunk }
      return { occurred_at: parseLocalMinute(m[1], tz), kind_label: m[2].trim(), author_name: m[3].trim(), body: m[4].trim() }
    })
}

/** Every non-empty cell of the row's columns, verbatim, minus the ignored ones. */
function zohoColumns(r: CsvRow, columns: string[], skip: readonly string[]): Record<string, string> {
  const out: Record<string, string> = {}
  for (const c of columns) if (!skip.includes(c) && (r[c] ?? '').trim() !== '') out[c] = r[c]
  return out
}

function contactRuleOf(rows: CsvRow[]): ContactRule | null {
  const labels = rows.map((r) => cell(r, COL.status))
  const never = labels.find((l) => ZOHO_STATUS_KEY[l] === 'never_contact')
  if (never !== undefined) return { rule: 'do_not_contact', reason: `Zoho: ${never}` }
  const later = labels.find((l) => ZOHO_STATUS_KEY[l] === 'contact_in_future' || ZOHO_STATUS_KEY[l] === 'rejected_hirable')
  return later === undefined ? null : { rule: 'contact_later', reason: `Zoho: ${later}` }
}

type Ctx = { tz: string; problems: JobViewProblem[]; candidateColumns: string[] }

function stamp(ctx: Ctx, ref: string, column: string, value: string): string | null {
  if (value === '') return null
  const iso = parseLocalMinute(value, ctx.tz)
  if (iso === null) ctx.problems.push({ ref, message: `${column} "${value}" is not a YYYY-MM-DD HH:MM stamp` })
  return iso
}

function buildCandidate(rows: CsvRow[], ctx: Ctx): JobViewCandidate {
  const r = rows[0]
  const id = cell(r, COL.candidateId)
  let source_key = 'imported'
  try {
    source_key = mapSource(cell(r, 'Source'))
  } catch (e) {
    if (!(e instanceof UnknownValueError)) throw e
    ctx.problems.push({ ref: id, message: e.message })
  }
  return {
    zoho_id: id,
    full_name: cell(r, 'Full Name') || id,
    email: candidateEmail({ Email: cell(r, 'Email') }).email,
    phone: candidatePhone({ Mobile: cell(r, 'Mobile / Phone') }).phone,
    linkedin_url: blank(cell(r, 'LinkedIn')),
    skills: candidateSkills(cell(r, 'Skill Set')).skills,
    source_key,
    owner_name: blank(cell(r, 'Candidate Owner')),
    last_activity_at: stamp(ctx, id, 'Candidate Last Activity', cell(r, 'Candidate Last Activity')),
    contact_rule: contactRuleOf(rows),
    custom: { zoho: zohoColumns(r, ctx.candidateColumns, []) },
  }
}

type JobRow = { application: JobViewApplication; notes: JobViewNote[]; statusKey: string }

function buildJobRow(r: CsvRow, jobColumns: string[], ctx: Ctx): JobRow | null {
  const candidate = cell(r, COL.candidateId)
  const job = cell(r, COL.jobId)
  const ref = `${candidate}/${job}`
  const label = cell(r, COL.status)
  const statusKey = Object.prototype.hasOwnProperty.call(ZOHO_STATUS_KEY, label) ? ZOHO_STATUS_KEY[label] : undefined
  if (statusKey === undefined) {
    ctx.problems.push({ ref, message: label === '' ? 'No status for this job' : `Unknown Zoho status "${label}"` })
    return null
  }
  const application: JobViewApplication = {
    candidate_zoho_id: candidate,
    job_display_id: job,
    sub_status_key: statusKey,
    received_at: stamp(ctx, ref, 'Associated On', cell(r, 'Associated On')) ?? stamp(ctx, ref, 'Candidate Last Activity', cell(r, 'Candidate Last Activity')),
    status_at: stamp(ctx, ref, 'Status Last Updated', cell(r, 'Status Last Updated')),
    hired_date: blank(cell(r, 'Hired Date')),
    owner_name: firstName(cell(r, 'Assigned Recruiter(s)')),
    custom: { zoho: zohoColumns(r, jobColumns, [COL.ignored, COL.notesLog]) },
  }
  const notes = splitNotesLog(r[COL.notesLog] ?? '', ctx.tz).map((n, i) => {
    if (n.kind_label === '') ctx.problems.push({ ref, message: `Job note ${i + 1} has no "[date] Kind – Author:" header` })
    return { candidate_zoho_id: candidate, job_display_id: job, seq: i + 1, ...n }
  })
  return { application, notes, statusKey }
}

function groupByCandidate(rows: CsvRow[], problems: JobViewProblem[]): Map<string, CsvRow[]> {
  const groups = new Map<string, CsvRow[]>()
  rows.forEach((r, i) => {
    if (Object.values(r).every((v) => v.trim() === '')) return // a row of bare commas
    const id = cell(r, COL.candidateId)
    if (id === '') {
      problems.push({ ref: `record ${i + 2}`, message: 'Blank Candidate ID' })
      return
    }
    groups.set(id, [...(groups.get(id) ?? []), r])
  })
  return groups
}

export function buildJobViewPayload(rows: CsvRow[], opts: { tz: string }): JobViewResult {
  const problems: JobViewProblem[] = []
  const header = rows.length > 0 ? Object.keys(rows[0]) : []
  const split = header.indexOf(JOB_COLUMNS_FROM)
  const ctx: Ctx = { tz: opts.tz, problems, candidateColumns: split < 0 ? header : header.slice(0, split) }
  const jobColumns = split < 0 ? [] : header.slice(split)

  const candidates: JobViewCandidate[] = []
  const applications: JobViewApplication[] = []
  const notes: JobViewNote[] = []
  const byStatus: Record<string, number> = {}
  for (const [id, group] of groupByCandidate(rows, problems)) {
    candidates.push(buildCandidate(group, ctx))
    const seen = new Set<string>()
    for (const r of group) {
      const job = cell(r, COL.jobId)
      if (job === '') continue
      if (seen.has(job)) {
        problems.push({ ref: `${id}/${job}`, message: 'The candidate has this job on two rows' })
        continue
      }
      seen.add(job)
      const built = buildJobRow(r, jobColumns, ctx)
      if (built === null) continue
      applications.push(built.application)
      notes.push(...built.notes)
      byStatus[built.statusKey] = (byStatus[built.statusKey] ?? 0) + 1
    }
  }
  return {
    payload: { candidates, applications, notes },
    counts: { candidates: candidates.length, applications: applications.length, notes: notes.length, byStatus },
    problems,
  }
}
