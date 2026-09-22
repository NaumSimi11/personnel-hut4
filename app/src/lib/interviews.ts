import { z } from 'zod'

/**
 * Interviews and scorecards (plan 018b). The database owns visibility (the
 * blind rule in RLS) and authorship (author_id must be the current person);
 * this file validates what the forms submit and shapes the criteria.
 */

export const INTERVIEW_KINDS = [
  { key: 'phone', label: 'Phone screen' },
  { key: 'technical', label: 'Technical' },
  { key: 'panel', label: 'Panel' },
  { key: 'final', label: 'Final' },
  { key: 'other', label: 'Other' },
] as const

export type InterviewKind = (typeof INTERVIEW_KINDS)[number]['key']

export const interviewInput = z.object({
  kind: z.enum(['phone', 'technical', 'panel', 'final', 'other']),
  scheduledAt: z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/, 'Choose the date and time.'),
  durationMinutes: z.coerce
    .number()
    .int()
    .min(15, 'Duration must be between 15 minutes and 8 hours.')
    .max(480, 'Duration must be between 15 minutes and 8 hours.'),
  location: z.string().trim().max(200, 'Keep the location under 200 characters.'),
  panel: z.array(z.string().min(1)).max(12, 'Keep the panel to twelve people or fewer.'),
})

export type InterviewInput = z.infer<typeof interviewInput>

// ------------------------------------------------------------------ criteria

export type Criterion = { id: string; label: string; description?: string }

export const DEFAULT_CRITERIA: Criterion[] = [
  { id: 'role_skills', label: 'Role skills', description: 'Can they do the work the job needs?' },
  { id: 'problem_solving', label: 'Problem solving', description: 'How they think through something unfamiliar.' },
  { id: 'communication', label: 'Communication', description: 'Clarity, listening, and how they explain decisions.' },
  { id: 'values', label: 'Working style & values', description: 'How they collaborate and take ownership.' },
]

/** The job's criteria when it has any, else the shared defaults; junk ignored. */
export function criteriaFor(raw: unknown): Criterion[] {
  if (!Array.isArray(raw)) return DEFAULT_CRITERIA
  const valid = raw.flatMap((item): Criterion[] => {
    if (!item || typeof item !== 'object') return []
    const record = item as Record<string, unknown>
    if (typeof record.id !== 'string' || typeof record.label !== 'string' || !record.id || !record.label) return []
    return [
      {
        id: record.id,
        label: record.label,
        ...(typeof record.description === 'string' && record.description && { description: record.description }),
      },
    ]
  })
  return valid.length ? valid : DEFAULT_CRITERIA
}

export const criteriaInput = z.array(
  z.object({
    id: z.string().min(1),
    label: z.string().trim().min(1, 'Every criterion needs a name.').max(80, 'Keep criterion names short.'),
    description: z.string().trim().max(200).optional(),
  }),
)

// ---------------------------------------------------------------- scorecards

export const RECOMMENDATIONS = [
  { key: 'strong_no', label: 'Strong no' },
  { key: 'no', label: 'No' },
  { key: 'yes', label: 'Yes' },
  { key: 'strong_yes', label: 'Strong yes' },
] as const

export type Recommendation = (typeof RECOMMENDATIONS)[number]['key']

export type Rating = { criterion_id: string; label: string; rating: number; evidence: string }

export type ScorecardForm = {
  ratings: Record<string, { rating: number | null; evidence: string }>
  recommendation: Recommendation | ''
  summary: string
}

/** Every criterion rated 1–4, a recommendation chosen; output snapshots the labels. */
export function scorecardInput(criteria: Criterion[]) {
  return z
    .object({
      ratings: z.record(z.object({ rating: z.number().nullable(), evidence: z.string() })),
      recommendation: z.enum(['strong_no', 'no', 'yes', 'strong_yes'], {
        errorMap: () => ({ message: 'Choose a recommendation.' }),
      }),
      summary: z.string().trim().max(2000, 'Keep the summary under 2000 characters.'),
    })
    .superRefine((input, ctx) => {
      for (const c of criteria) {
        const r = input.ratings[c.id]
        if (!r || r.rating === null || !Number.isInteger(r.rating) || r.rating < 1 || r.rating > 4) {
          ctx.addIssue({ code: z.ZodIssueCode.custom, message: `Rate "${c.label}" from 1 to 4.`, path: ['ratings', c.id] })
          return
        }
      }
    })
    .transform((input) => ({
      ratings: criteria.map(
        (c): Rating => ({
          criterion_id: c.id,
          label: c.label,
          rating: input.ratings[c.id]?.rating ?? 0,
          evidence: (input.ratings[c.id]?.evidence ?? '').trim(),
        }),
      ),
      recommendation: input.recommendation,
      summary: input.summary,
    }))
}

export function emptyScorecardForm(criteria: Criterion[]): ScorecardForm {
  return {
    ratings: Object.fromEntries(criteria.map((c) => [c.id, { rating: null, evidence: '' }])),
    recommendation: '',
    summary: '',
  }
}

export function recommendationLabel(key: string): string {
  return RECOMMENDATIONS.find((r) => r.key === key)?.label ?? key
}

// ------------------------------------------------------ imported interviews

/** Provider value of a row the Zoho history import wrote (plan 055). */
export const ZOHO_PROVIDER = 'zoho_recruit'

/** What custom.zoho carries on an imported interview; every field optional there. */
export type ZohoInterviewMeta = {
  name: string | null
  outcome: string | null
  interviewers: string[]
}

function textOrNull(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

/**
 * custom.zoho as the import writes it (D3): `name`, `outcome`, and the
 * `interviewers` we could not link to people. `custom` is unknown JSON, so
 * every field is checked and junk is dropped; null when there is no zoho
 * object at all.
 */
export function zohoInterviewMeta(custom: unknown): ZohoInterviewMeta | null {
  if (!custom || typeof custom !== 'object' || Array.isArray(custom)) return null
  const zoho = (custom as { zoho?: unknown }).zoho
  if (!zoho || typeof zoho !== 'object' || Array.isArray(zoho)) return null
  const record = zoho as Record<string, unknown>
  const interviewers = Array.isArray(record.interviewers)
    ? record.interviewers.flatMap((v) => {
        const name = textOrNull(v)
        return name ? [name] : []
      })
    : []
  return { name: textOrNull(record.name), outcome: textOrNull(record.outcome), interviewers }
}

type ImportedInterview = { provider: string | null; custom: unknown }

/** "Imported from Zoho Recruit · <name> · outcome: <…>" for an imported row; null otherwise. */
export function interviewImportLine(i: ImportedInterview): string | null {
  if (i.provider !== ZOHO_PROVIDER) return null
  const meta = zohoInterviewMeta(i.custom)
  return `Imported from Zoho Recruit · ${meta?.name ?? 'Interview'} · outcome: ${meta?.outcome ?? '—'}`
}

/** The interviewers the import could not link, after the panel; null when none. */
export function interviewUnresolvedPanelLine(i: ImportedInterview): string | null {
  if (i.provider !== ZOHO_PROVIDER) return null
  const names = zohoInterviewMeta(i.custom)?.interviewers ?? []
  return names.length ? `Also on the panel: ${names.join(', ')}` : null
}
