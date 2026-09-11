import { z } from 'zod'

/**
 * Pure logic for the job workspace (plan 017): the five-step journey, the
 * job status lifecycle, screening questions, and the promotion state machine
 * as the UI sees it. The database enforces every transition (jobs RLS,
 * job_channels RLS, advance_promotion in migration 0012); this file decides
 * what to offer.
 */

// ------------------------------------------------------------------ journey

export type StepId = 'request' | 'job' | 'publish' | 'applications' | 'hire'

export const JOB_STEPS: { id: StepId; number: string; label: string }[] = [
  { id: 'request', number: '01', label: 'Hiring request' },
  { id: 'job', number: '02', label: 'Job ready' },
  { id: 'publish', number: '03', label: 'Published' },
  { id: 'applications', number: '04', label: 'Applications' },
  { id: 'hire', number: '05', label: 'Hired' },
]

export type ChannelLite = { channel_key: string; status: string; published_revision: number | null }

const PUBLISHED_STATUSES = new Set(['submitted', 'live', 'closing'])

export function isPublished(channel: ChannelLite): boolean {
  return PUBLISHED_STATUSES.has(channel.status)
}

/** The furthest step the job has reached; later evidence wins over earlier gaps. */
export function currentStep(input: {
  status: string
  channels: ChannelLite[]
  applications: number
  hired: number
}): StepId {
  if (input.hired > 0) return 'hire'
  if (input.applications > 0) return 'applications'
  if (input.channels.some(isPublished)) return 'publish'
  if (input.status !== 'draft') return 'job'
  return 'request'
}

export function stepIndex(step: StepId): number {
  return JOB_STEPS.findIndex((s) => s.id === step)
}

// ------------------------------------------------------------ job lifecycle

export type JobStatusAction = { to: string; label: string }

export function jobStatusActions(input: { status: string; hasDescription: boolean }): JobStatusAction[] {
  switch (input.status) {
    case 'draft':
      return input.hasDescription ? [{ to: 'ready', label: 'Mark ready' }] : []
    case 'ready':
      return [{ to: 'open', label: 'Open job' }]
    case 'open':
      return [
        { to: 'on_hold', label: 'Put on hold' },
        { to: 'closed', label: 'Close job' },
      ]
    case 'on_hold':
      return [
        { to: 'open', label: 'Reopen' },
        { to: 'closed', label: 'Close job' },
      ]
    case 'closed':
      return [{ to: 'open', label: 'Reopen' }]
    case 'filled':
      return [{ to: 'closed', label: 'Close job' }]
    default:
      return []
  }
}

// ------------------------------------------------------ screening questions

export const QUESTION_KINDS = ['text', 'yes_no', 'choice'] as const

export const screeningQuestionsInput = z.array(
  z
    .object({
      id: z.string().min(1),
      prompt: z.string().trim().min(1, 'Every question needs a prompt.').max(300, 'Keep prompts under 300 characters.'),
      kind: z.enum(QUESTION_KINDS),
      required: z.boolean(),
      options: z.array(z.string().trim().min(1, 'Options cannot be empty.')).optional(),
    })
    .refine((q) => q.kind !== 'choice' || (q.options?.length ?? 0) >= 2, {
      message: 'Give a choice question at least two options.',
      path: ['options'],
    }),
)

export type ScreeningQuestion = z.infer<typeof screeningQuestionsInput>[number]

export function newQuestion(): ScreeningQuestion {
  return { id: crypto.randomUUID(), prompt: '', kind: 'text', required: true }
}

/**
 * Stored questions that do not match the schema are repaired item by item
 * rather than dropped, so an edit-and-save never silently erases them. A
 * value that is not a list at all is reported as lossy: the editor must
 * refuse to save over it.
 */
export function salvageQuestions(raw: unknown): { questions: ScreeningQuestion[]; lossy: boolean } {
  const strict = screeningQuestionsInput.safeParse(raw)
  if (strict.success) return { questions: strict.data, lossy: false }
  if (!Array.isArray(raw)) return { questions: [], lossy: true }
  const questions = raw.map((item): ScreeningQuestion => {
    const record = item && typeof item === 'object' ? (item as Record<string, unknown>) : {}
    const kind = QUESTION_KINDS.find((k) => k === record.kind) ?? 'text'
    const options = Array.isArray(record.options)
      ? record.options.filter((o): o is string => typeof o === 'string' && o.trim().length > 0)
      : undefined
    return {
      id: typeof record.id === 'string' && record.id ? record.id : crypto.randomUUID(),
      prompt: typeof record.prompt === 'string' ? record.prompt : '',
      kind,
      required: record.required === true,
      ...(options && { options }),
    }
  })
  return { questions, lossy: false }
}

// ---------------------------------------------------------------- promotion

export type PromotionAction = { to: string; label: string }

/**
 * Mirrors advance_promotion's transition table so the UI shows only what the
 * database would accept. `can` answers capability questions for the
 * promotion's company.
 */
export function promotionActions(
  promo: { status: string; drafted_by: string | null },
  personId: string | null,
  can: (capability: string) => boolean,
): PromotionAction[] {
  const actions: PromotionAction[] = []
  switch (promo.status) {
    case 'requested':
    case 'changes_requested':
      if (can('marketing.draft')) actions.push({ to: 'draft', label: 'Save draft' })
      break
    case 'draft':
      if (can('marketing.draft')) {
        actions.push({ to: 'draft', label: 'Save draft' }, { to: 'in_review', label: 'Submit for review' })
      }
      break
    case 'in_review':
      if (can('marketing.approve') && promo.drafted_by !== personId) {
        actions.push({ to: 'approved', label: 'Approve' }, { to: 'changes_requested', label: 'Request changes' })
      }
      break
    case 'approved':
      if (can('marketing.publish')) actions.push({ to: 'published', label: 'Record publication' })
      break
    default:
      break
  }
  return actions
}

export function friendlyRecruitmentError(message: string): string {
  if (/row-level security/.test(message)) return 'You do not have permission for this action in this company.'
  return message
}
