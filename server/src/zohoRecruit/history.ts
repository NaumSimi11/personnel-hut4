import fs from 'node:fs'
import path from 'node:path'
import type { CsvRow } from './csv.js'
import { readCsv } from './csv.js'
import { parseUsDateTime } from './dates.js'
import { rewriteMentions } from './mapping.js'

/**
 * The export → the `import_zoho_history` payload (plan 055 D2–D4): the
 * person-level candidate notes, the interviews and the reviews. Pure: rows
 * in, JSON out. Nothing is guessed — a date that cannot be read, an
 * interview with no From at all (import_zoho_history refuses a null
 * scheduled_at at commit) or a rating outside 1..4 is a problem, and the
 * rows the SQL must decide about (an unmatched interview, a duplicate
 * review) stay in the payload and are only counted here.
 *
 * The note prefix is deliberately not built here: D2 attaches it only when
 * the actor could not be linked to a person, which `import_zoho_history`
 * learns in pass 1, not the extract.
 */

export type HistoryUser = { zoho_id: string; email: string; name: string }

export type HistoryNote = {
  zoho_id: string
  candidate_zoho_id: string
  kind: NoteKind
  zoho_type: string
  body: string
  actor_zoho_id: string | null
  actor_name: string | null
  created_at: string | null
}

export type HistoryInterview = {
  zoho_id: string
  candidate_zoho_id: string
  job_zoho_id: string
  name: string
  kind: 'phone' | 'other'
  scheduled_at: string | null
  duration_minutes: number
  location: string | null
  status: 'completed' | 'cancelled'
  outcome: string | null
  notes: string | null
  owner_zoho_id: string | null
  interviewer_zoho_ids: string[]
  cancellation_reason: string | null
  created_at: string | null
}

export type HistoryReview = {
  zoho_id: string
  interview_zoho_id: string | null
  rating: number
  recommendation: Recommendation
  comments: string | null
  summary: string | null
  source: string | null
  author_zoho_id: string | null
  created_at: string | null
}

/** Exactly the four keys `public.import_zoho_history(p_payload, p_commit)` reads (plan 055 §1). */
export type HistoryPayload = {
  users: HistoryUser[]
  candidate_notes: HistoryNote[]
  interviews: HistoryInterview[]
  reviews: HistoryReview[]
}

export type HistoryProblem = { kind: 'note' | 'interview' | 'review'; ref: string; message: string }

export type HistoryCounts = {
  users: number
  notes: { imported: number; skipped_modules: number; already_attached: number; truncated: number }
  interviews: { matched: number; unmatched: number }
  reviews: { matched: number; unmatched: number; duplicates: number }
  problems: number
}

export type HistoryResult = { payload: HistoryPayload; counts: HistoryCounts; problems: HistoryProblem[] }

// ----------------------------------------------------------------- tables

/** The six tables the history extract reads, by the file name Zoho gives them. */
export const HISTORY_FILES = {
  users: 'Users_001.csv',
  associations: 'Associated_001.csv',
  notes: 'Notes_001.csv',
  interviews: 'Interviews_001.csv',
  reviews: 'Reviews_001.csv',
  assessments: 'Reviews_Asssessment.csv',
} as const

export type HistoryExport = { -readonly [K in keyof typeof HISTORY_FILES]: CsvRow[] }

export function readHistoryExport(dir: string): HistoryExport {
  const out: Partial<HistoryExport> = {}
  for (const [key, file] of Object.entries(HISTORY_FILES) as [keyof typeof HISTORY_FILES, string][]) {
    const full = path.join(dir, file)
    if (!fs.existsSync(full)) throw new Error(`Export table missing: ${full}`)
    out[key] = readCsv(full)
  }
  return out as HistoryExport
}

// ------------------------------------------------------------------- maps

export type NoteKind =
  | 'note' | 'call' | 'message' | 'meeting' | 'status_change'
  | 'association' | 'unassociation' | 'review' | 'task' | 'other'

export type Recommendation = 'strong_yes' | 'yes' | 'no' | 'strong_no'

const NOTE_KIND_BY_TYPE: Readonly<Record<string, NoteKind>> = {
  Notes: 'note',
  Call: 'call',
  Meeting: 'meeting',
  'Change Status': 'status_change',
  Association: 'association',
  Unassociation: 'unassociation',
  'General Review': 'review',
  TASK: 'task',
  Others: 'other',
}

const LINKEDIN = /^linkedin msgs\b/i
const CANDIDATES_MODULE = 'Candidates'
const BODY_MAX = 4000
const ELLIPSIS = ' …'
const DURATION_MIN = 15
const DURATION_MAX = 480
const DURATION_DEFAULT = 60
const RATING_MIN = 1
const RATING_MAX = 4
const CANCELLED = 'Cancelled'

const RECOMMENDATION_BY_RATING: Readonly<Record<number, Recommendation>> = {
  4: 'strong_yes',
  3: 'yes',
  2: 'no',
  1: 'strong_no',
}

/** D2: the Zoho note type → our `candidate_notes.kind`; anything unlisted is `other`. */
export function noteKind(zohoType: string): NoteKind {
  const type = zohoType.trim()
  if (LINKEDIN.test(type)) return 'message'
  return NOTE_KIND_BY_TYPE[type] ?? 'other'
}

/** The body the CHECK allows: trimmed, 4,000 characters, a longer one cut with " …". */
export function noteBody(text: string): { body: string; truncated: boolean } {
  const trimmed = text.trim()
  if (trimmed.length <= BODY_MAX) return { body: trimmed, truncated: false }
  return { body: `${trimmed.slice(0, BODY_MAX - ELLIPSIS.length)}${ELLIPSIS}`, truncated: true }
}

/** D3: the Zoho interview name decides the kind; only "phone" is a kind of ours. */
export function interviewKind(name: string): 'phone' | 'other' {
  return name.toLowerCase().includes('phone') ? 'phone' : 'other'
}

/** D3: To − From in minutes, clamped 15..480; 60 when either stamp is missing or the span is not positive. */
export function durationMinutes(fromIso: string | null, toIso: string | null): number {
  if (!fromIso || !toIso) return DURATION_DEFAULT
  const minutes = Math.round((Date.parse(toIso) - Date.parse(fromIso)) / 60000)
  if (!Number.isFinite(minutes) || minutes <= 0) return DURATION_DEFAULT
  return Math.min(Math.max(minutes, DURATION_MIN), DURATION_MAX)
}

/** D4: Zoho's 1..4 rating is our scale; 4 is a strong yes. */
export function recommendationOf(rating: number): Recommendation {
  return RECOMMENDATION_BY_RATING[rating]
}

/** D3: the two free-text fields of an interview, as one note or none. */
export function interviewNotes(feedback: string | null, scheduleComments: string | null): string | null {
  const parts = [
    feedback === null ? null : `Feedback: ${feedback}`,
    scheduleComments === null ? null : `Schedule comments: ${scheduleComments}`,
  ].filter((part): part is string => part !== null)
  return parts.length ? parts.join('\n\n') : null
}

/** D4: the comments, then the assessment's question/answer lines, a blank line apart. */
export function reviewSummary(comments: string | null, answers: { question: string; answer: string }[]): string | null {
  const lines = answers.map((a) => `Q: ${a.question} — A: ${a.answer}`)
  const parts = [comments, lines.length ? lines.join('\n') : null].filter((part): part is string => part !== null && part !== '')
  return parts.length ? parts.join('\n\n') : null
}

// ------------------------------------------------------------------ build

const blank = (value: string | null | undefined): string | null => {
  const trimmed = (value ?? '').trim()
  return trimmed === '' ? null : trimmed
}

/** Trim, drop blanks — the interviewer list is separated by "," or ";". */
const splitIds = (value: string | null | undefined): string[] =>
  (value ?? '').split(/[,;]/).map((part) => part.trim()).filter((part) => part !== '')

type Ctx = { tz: string; users: Map<string, string>; problems: HistoryProblem[] }

/** A stamp in the export's zone; blank is no date, an unreadable one is a problem (the 052 rule). */
function stamp(ctx: Ctx, kind: HistoryProblem['kind'], ref: string, column: string, value: string | undefined): string | null {
  const raw = (value ?? '').trim()
  if (raw === '') return null
  const parsed = parseUsDateTime(raw, ctx.tz)
  if (parsed === null) ctx.problems.push({ kind, ref, message: `${column} "${raw}" is not a date` })
  return parsed
}

function buildUsers(rows: CsvRow[]): HistoryUser[] {
  // Mirrors payload.ts's users block: the same list, so the same people resolve.
  return rows.map((u) => ({
    zoho_id: u['User ID'],
    email: u.Email.trim().toLowerCase(),
    name: [blank(u['First Name']), blank(u['Last Name'])].filter((part) => part).join(' ') || u.Email.trim().toLowerCase(),
  }))
}

type NoteOutcome = { note: HistoryNote; truncated: boolean } | { left: 'skipped_modules' | 'already_attached' | 'problem' }

/**
 * D2: a Candidates-module note that 052 did not already attach to an
 * application. The candidate is the note's own id, else its parent.
 */
function buildNote(n: CsvRow, pairs: ReadonlySet<string>, ctx: Ctx): NoteOutcome {
  const ref = n['Note Id']
  if (n.Module !== CANDIDATES_MODULE) return { left: 'skipped_modules' }
  const candidate = blank(n['Candidate Id']) ?? blank(n['Parent ID'])
  const job = blank(n['Job Opening Id'])
  if (candidate === null) {
    ctx.problems.push({ kind: 'note', ref, message: 'the note names no candidate' })
    return { left: 'problem' }
  }
  // 052 imported the notes whose (candidate, job) pair is an association.
  if (job !== null && pairs.has(`${candidate}|${job}`)) return { left: 'already_attached' }
  const { body, truncated } = noteBody(rewriteMentions(n['Note Content'] ?? '', ctx.users))
  if (body === '') {
    ctx.problems.push({ kind: 'note', ref, message: 'the note has no body' })
    return { left: 'problem' }
  }
  const actorZohoId = blank(n['Created By'])
  const zohoType = (n['Note Type'] ?? '').trim() || 'Notes'
  return {
    note: {
      zoho_id: ref,
      candidate_zoho_id: candidate,
      kind: noteKind(zohoType),
      zoho_type: zohoType,
      body,
      actor_zoho_id: actorZohoId,
      actor_name: (actorZohoId && ctx.users.get(actorZohoId)) ?? null,
      created_at: stamp(ctx, 'note', ref, 'Created Time', n['Created Time']),
    },
    truncated,
  }
}

function buildInterview(i: CsvRow, ctx: Ctx): HistoryInterview {
  const ref = i['Interview Id']
  const name = blank(i['Interview Name']) ?? ''
  const scheduledAt = stamp(ctx, 'interview', ref, 'From', i.From)
  // A blank From is a valid "no stamp" for `stamp()`, but import_zoho_history
  // refuses a null scheduled_at at commit — an unparseable From already
  // raised a problem above, so this only covers the blank case.
  if (scheduledAt === null && blank(i.From) === null) {
    ctx.problems.push({ kind: 'interview', ref, message: 'the interview has no From date' })
  }
  const endsAt = stamp(ctx, 'interview', ref, 'To', i.To)
  const status = blank(i['Interview Status'])
  return {
    zoho_id: ref,
    candidate_zoho_id: i['Candidate ID'],
    job_zoho_id: i['Job Opening ID'],
    name,
    kind: interviewKind(name),
    scheduled_at: scheduledAt,
    duration_minutes: durationMinutes(scheduledAt, endsAt),
    location: blank(i.Location),
    status: status === CANCELLED ? 'cancelled' : 'completed',
    outcome: status,
    notes: interviewNotes(blank(i.Feedback), blank(i['Schedule Comments'])),
    owner_zoho_id: blank(i['Interview Owner ID']),
    interviewer_zoho_ids: splitIds(i['Interviewer(s)']),
    cancellation_reason: blank(i['Cancellation Reason']),
    created_at: stamp(ctx, 'interview', ref, 'Created Time', i['Created Time']),
  }
}

type ReviewOutcome = { review: HistoryReview } | { left: 'problem' }

function buildReview(r: CsvRow, answers: { question: string; answer: string }[], ctx: Ctx): ReviewOutcome {
  const ref = r['Review Id']
  const raw = (r.Rating ?? '').trim()
  const parsed = Number(raw)
  const rating = raw === '' || !Number.isFinite(parsed) ? null : Math.round(parsed)
  if (rating === null || rating < RATING_MIN || rating > RATING_MAX) {
    ctx.problems.push({ kind: 'review', ref, message: `Rating "${raw}" is not 1..4` })
    return { left: 'problem' }
  }
  const comments = blank(r['Review Comments'])
  return {
    review: {
      zoho_id: ref,
      interview_zoho_id: blank(r['Interview ID']),
      rating,
      recommendation: recommendationOf(rating),
      comments,
      summary: reviewSummary(comments, answers),
      source: blank(r.Source),
      author_zoho_id: blank(r['Created By']),
      created_at: stamp(ctx, 'review', ref, 'Created Time', r['Created Time']),
    },
  }
}

/** The assessment's question/answer rows per review, in file order. */
function answersByReview(rows: CsvRow[]): Map<string, { question: string; answer: string }[]> {
  const out = new Map<string, { question: string; answer: string }[]>()
  for (const row of rows) {
    const question = blank(row.Question)
    const answer = blank(row.Answer)
    if (question === null && answer === null) continue
    const ref = row['Review Id']
    out.set(ref, [...(out.get(ref) ?? []), { question: question ?? '—', answer: answer ?? '—' }])
  }
  return out
}

export function buildHistory(exp: HistoryExport, opts: { tz: string }): HistoryResult {
  const users = buildUsers(exp.users)
  const ctx: Ctx = { tz: opts.tz, users: new Map(users.map((u) => [u.zoho_id, u.name])), problems: [] }

  const pairs = new Set(exp.associations.map((a) => `${a['Candidate ID']}|${a['Job Opening ID']}`))
  const noteCounts = { imported: 0, skipped_modules: 0, already_attached: 0, truncated: 0 }
  const candidateNotes: HistoryNote[] = []
  for (const row of exp.notes) {
    const outcome = buildNote(row, pairs, ctx)
    if ('note' in outcome) {
      candidateNotes.push(outcome.note)
      noteCounts.imported += 1
      if (outcome.truncated) noteCounts.truncated += 1
    } else if (outcome.left !== 'problem') {
      noteCounts[outcome.left] += 1
    }
  }

  // Every interview goes in the payload — the SQL owns the matching; the
  // counts here are the report the maintainer reads before committing.
  const interviews = exp.interviews.map((row) => buildInterview(row, ctx))
  const interviewIds = new Set(interviews.map((i) => i.zoho_id))
  const matchedInterviews = interviews.filter((i) => pairs.has(`${i.candidate_zoho_id}|${i.job_zoho_id}`)).length

  const answers = answersByReview(exp.assessments)
  const reviews: HistoryReview[] = []
  const seen = new Set<string>()
  const reviewCounts = { matched: 0, unmatched: 0, duplicates: 0 }
  for (const row of exp.reviews) {
    const outcome = buildReview(row, answers.get(row['Review Id']) ?? [], ctx)
    if (!('review' in outcome)) continue
    const review = outcome.review
    reviews.push(review)
    if (review.interview_zoho_id !== null && interviewIds.has(review.interview_zoho_id)) reviewCounts.matched += 1
    else reviewCounts.unmatched += 1
    const pair = `${review.interview_zoho_id ?? ''}|${review.author_zoho_id ?? ''}`
    if (seen.has(pair)) reviewCounts.duplicates += 1
    seen.add(pair)
  }

  return {
    payload: { users, candidate_notes: candidateNotes, interviews, reviews },
    counts: {
      users: users.length,
      notes: noteCounts,
      interviews: { matched: matchedInterviews, unmatched: interviews.length - matchedInterviews },
      reviews: reviewCounts,
      problems: ctx.problems.length,
    },
    problems: ctx.problems,
  }
}
