import { z } from 'zod'
import { longDate } from '@/lib/candidatePool'

/**
 * The yearly equipment check (24 Nov, migration 0130): the General
 * Administrator starts one per company with a deadline; everyone holding
 * equipment answers for each item. The database checks who may answer what.
 */
export type CheckAnswer = 'have' | 'missing' | 'issue'

export const CHECK_ANSWERS: ReadonlyArray<{ key: CheckAnswer; label: string; needsNote: boolean }> = [
  { key: 'have', label: 'I still have and use it', needsNote: false },
  { key: 'missing', label: 'I no longer have it', needsNote: true },
  { key: 'issue', label: 'I have it, but something is wrong', needsNote: true },
]

export const NOTE_MAX = 500

export const answerInput = z
  .object({
    answer: z.enum(['have', 'missing', 'issue']),
    note: z.string().trim().max(NOTE_MAX, `Keep the note under ${NOTE_MAX} characters.`),
  })
  .superRefine((v, ctx) => {
    if (v.answer !== 'have' && v.note.length < 3) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['note'], message: 'Say what happened, in a few words.' })
    }
  })

type ItemLite = { answer: string | null; followed_up_at: string | null }

export function needsFollowUp(item: ItemLite): boolean {
  return (item.answer === 'missing' || item.answer === 'issue') && !item.followed_up_at
}

export function checkProgress(items: ReadonlyArray<ItemLite>) {
  return {
    total: items.length,
    have: items.filter((i) => i.answer === 'have').length,
    missing: items.filter((i) => i.answer === 'missing').length,
    issue: items.filter((i) => i.answer === 'issue').length,
    open: items.filter((i) => !i.answer).length,
    toFollowUp: items.filter(needsFollowUp).length,
  }
}

export function checkLine(check: { name: string; deadline: string }): string {
  return `${check.name} · answer by ${longDate(check.deadline)}`
}
