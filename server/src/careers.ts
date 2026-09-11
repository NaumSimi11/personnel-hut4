import { z } from 'zod'

/**
 * Careers intake, pure logic (plan 019). The public pages and the
 * application form talk only to the auth service; this module holds the
 * rules the routes apply — rate limiting, input shape, the honeypot, what a
 * candidate may see of a company and a job, and the duplicate rule from the
 * blueprint (§5): never silently merge, never accept the same person twice
 * for the same open role.
 */

// ---------------------------------------------------------------- rate limit

export class RateLimiter {
  private readonly hits = new Map<string, number[]>()
  private readonly max: number
  private readonly windowMs: number
  private readonly now: () => number

  constructor(options: { max: number; windowMs: number; now?: () => number }) {
    this.max = options.max
    this.windowMs = options.windowMs
    this.now = options.now ?? (() => Date.now())
  }

  /** Records the attempt and says whether it is within the sliding window. */
  allow(key: string): boolean {
    if (!this.peek(key)) return false
    this.record(key)
    return true
  }

  /** Would another attempt be within the window? Spends nothing. */
  peek(key: string): boolean {
    const at = this.now()
    this.evict(at)
    const recent = (this.hits.get(key) ?? []).filter((t) => at - t < this.windowMs)
    if (recent.length) this.hits.set(key, recent)
    else this.hits.delete(key)
    return recent.length < this.max
  }

  /** Spends one attempt — call once the work it guards has actually happened. */
  record(key: string): void {
    const at = this.now()
    const recent = (this.hits.get(key) ?? []).filter((t) => at - t < this.windowMs)
    this.hits.set(key, [...recent, at])
  }

  /** Keys tracked right now — for tests and diagnostics. */
  get size(): number {
    return this.hits.size
  }

  // Keys are partly attacker-chosen (email addresses), so the map must not
  // grow forever: drop every key whose attempts have all left the window.
  private evict(at: number): void {
    for (const [key, times] of this.hits) {
      if (times.every((t) => at - t >= this.windowMs)) this.hits.delete(key)
    }
  }
}

// --------------------------------------------------------------------- input

const answerRows = z.array(z.object({ question_id: z.string().min(1), answer: z.string().trim().max(2000) }))

function parseAnswers(raw: unknown): z.infer<typeof answerRows> {
  if (typeof raw !== 'string' || !raw) return []
  try {
    const parsed = answerRows.safeParse(JSON.parse(raw))
    return parsed.success ? parsed.data : []
  } catch {
    return []
  }
}

export const applicationInput = z.object({
  name: z.string().trim().min(2, 'Enter your full name.').max(120),
  email: z.string().trim().toLowerCase().email('Enter a valid email address.').max(320),
  phone: z.string().trim().max(40).optional().default(''),
  answers: z.unknown().transform(parseAnswers),
  consent: z
    .union([z.literal('true'), z.literal('on'), z.literal(true)])
    .transform(() => true as const)
    .catch(false as never),
})
  .refine((input) => input.consent === true, {
    message: 'Please confirm you are happy for us to process your application.',
    path: ['consent'],
  })

export type ApplicationInput = z.infer<typeof applicationInput>

/**
 * The hidden field real browsers leave empty and bots fill in. Its name must
 * not look like anything a password manager or autofill would populate —
 * a real applicant whose browser filled it would be dropped silently.
 */
export const HONEYPOT_FIELD = 'ref_x7'

export function isHoneypotTripped(fields: Record<string, string | undefined>): boolean {
  const value = fields[HONEYPOT_FIELD]
  return typeof value === 'string' && value.trim().length > 0
}

export const CV_MAX_BYTES = 10 * 1024 * 1024
const CV_TYPES: Record<string, string> = {
  'application/pdf': 'pdf',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
}

export function validateCv(file: { mimetype: string; size: number; filename: string }): string | null {
  if (!CV_TYPES[file.mimetype]) return 'Attach your CV as a PDF or Word document.'
  if (file.size > CV_MAX_BYTES) return 'Your CV must be 10 MB or smaller.'
  return null
}

export function cvExtension(mimetype: string): string {
  return CV_TYPES[mimetype] ?? 'bin'
}

// ---------------------------------------------------------------- public view

type CompanyRow = { id: string; name: string; short_code: string; website: string | null; brand: unknown }

export type PublicCompany = {
  name: string
  code: string
  website: string | null
  tagline: string | null
  accentColor: string | null
  logoUrl: string | null
}

function brandString(brand: unknown, key: string): string | null {
  if (!brand || typeof brand !== 'object') return null
  const value = (brand as Record<string, unknown>)[key]
  return typeof value === 'string' && value ? value : null
}

export function publicCompany(company: CompanyRow, supabaseUrl: string): PublicCompany {
  const logoPath = brandString(company.brand, 'logo_path')
  return {
    name: company.name,
    code: company.short_code,
    website: company.website,
    tagline: brandString(company.brand, 'tagline'),
    accentColor: brandString(company.brand, 'accent_color'),
    logoUrl: logoPath ? `${supabaseUrl.replace(/\/$/, '')}/storage/v1/object/public/company-logos/${logoPath}` : null,
  }
}

export type PublicQuestion = {
  id: string
  prompt: string
  kind: 'text' | 'yes_no' | 'choice'
  required: boolean
  options?: string[]
}

export type PublicBrief = { id: string; title: string; description: string; questions: PublicQuestion[] }

const KINDS = new Set(['text', 'yes_no', 'choice'])

function publicQuestions(raw: unknown): PublicQuestion[] {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((item): PublicQuestion[] => {
    if (!item || typeof item !== 'object') return []
    const q = item as Record<string, unknown>
    if (typeof q.id !== 'string' || typeof q.prompt !== 'string' || !q.prompt.trim()) return []
    const kind = KINDS.has(q.kind as string) ? (q.kind as PublicQuestion['kind']) : 'text'
    const options = Array.isArray(q.options) ? q.options.filter((o): o is string => typeof o === 'string') : undefined
    return [
      {
        id: q.id,
        prompt: q.prompt,
        kind,
        required: q.required === true,
        ...(kind === 'choice' && options && { options }),
      },
    ]
  })
}

export function publicBrief(job: {
  id: string
  title: string
  description: string | null
  screening_questions: unknown
  [internal: string]: unknown // whatever else the row carries stays here
}): PublicBrief {
  return {
    id: job.id,
    title: job.title,
    description: job.description ?? '',
    questions: publicQuestions(job.screening_questions),
  }
}

export function summaryOf(description: string | null, max = 200): string {
  const text = (description ?? '').replace(/\s+/g, ' ').trim()
  return text.length > max ? `${text.slice(0, max - 1).trimEnd()}…` : text
}

// ----------------------------------------------------------------- duplicates

const TERMINAL = new Set(['hired', 'rejected', 'withdrawn'])

/** The same person applying again for a role they are still in the running for. */
export function isDuplicateApplication(existing: { stage_key: string }[]): boolean {
  return existing.some((a) => !TERMINAL.has(a.stage_key))
}

/** What the candidate gets back — enough to quote, not an internal id. */
export function referenceFor(applicationId: string): string {
  return applicationId.replace(/-/g, '').slice(0, 8).toUpperCase()
}

// ------------------------------------------------------------------- answers

type AnswerRow = { question_id: string; answer: string }

/**
 * Server-side truth for the screening answers: every required question is
 * answered, closed questions carry one of their allowed values, and answers
 * to questions the job does not ask are dropped.
 */
export function checkAnswers(
  questions: unknown,
  answers: AnswerRow[],
): { ok: true; answers: AnswerRow[] } | { ok: false; error: string } {
  const byId = new Map(answers.map((a) => [a.question_id, a.answer.trim()]))
  const kept: AnswerRow[] = []
  for (const q of publicQuestions(questions)) {
    const answer = byId.get(q.id) ?? ''
    if (q.kind === 'yes_no' && answer && !['yes', 'no'].includes(answer)) {
      return { ok: false, error: `Please answer: ${q.prompt}` }
    }
    if (q.kind === 'choice' && answer && !(q.options ?? []).includes(answer)) {
      return { ok: false, error: `Choose one of the options for: ${q.prompt}` }
    }
    if (q.required && !answer) return { ok: false, error: `Please answer: ${q.prompt}` }
    if (answer) kept.push({ question_id: q.id, answer })
  }
  return { ok: true, answers: kept }
}

/** Company codes are 2–6 letters or digits — never a LIKE pattern. */
export function isShortCode(value: string): boolean {
  return /^[A-Za-z0-9]{2,6}$/.test(value)
}

// ------------------------------------------------------------- serialisation

const inFlight = new Map<string, Promise<unknown>>()

/**
 * Runs `fn` after any earlier call for the same key has settled, so a
 * read-then-insert per applicant cannot race with itself inside this process.
 * The database's unique index is the hard guarantee across processes; this
 * keeps the friendly 409 path the common one.
 */
export async function serialised<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const previous = inFlight.get(key) ?? Promise.resolve()
  const run = previous.then(fn, fn)
  const tracked = run.then(
    () => undefined,
    () => undefined,
  )
  inFlight.set(key, tracked)
  try {
    return await run
  } finally {
    if (inFlight.get(key) === tracked) inFlight.delete(key)
  }
}
