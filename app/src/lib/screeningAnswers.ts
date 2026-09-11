import type { ScreeningQuestion } from '@/lib/jobWorkspace'

/**
 * Screening answers (plan 018a) live on the application as
 * [{ question_id, answer }] against the job's current screening questions.
 * The view pairs them up; questions since removed from the job keep their
 * answers, marked as orphaned, so nothing a candidate said is lost.
 */

export type ScreeningAnswer = { question_id: string; answer: string }

export type AnswerRow = {
  question: ScreeningQuestion
  answer: string
  orphaned: boolean
}

function readAnswers(raw: unknown): ScreeningAnswer[] {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((item) => {
    if (!item || typeof item !== 'object') return []
    const record = item as Record<string, unknown>
    if (typeof record.question_id !== 'string') return []
    return [{ question_id: record.question_id, answer: typeof record.answer === 'string' ? record.answer : '' }]
  })
}

export function mergeAnswers(questions: ScreeningQuestion[], raw: unknown): AnswerRow[] {
  const answers = readAnswers(raw)
  const byQuestion = new Map(answers.map((a) => [a.question_id, a.answer]))
  const rows: AnswerRow[] = questions.map((question) => ({
    question,
    answer: byQuestion.get(question.id) ?? '',
    orphaned: false,
  }))
  const known = new Set(questions.map((q) => q.id))
  const orphans: AnswerRow[] = answers
    .filter((a) => !known.has(a.question_id) && a.answer.trim() !== '')
    .map((a) => ({
      question: { id: a.question_id, prompt: 'Question no longer on the job', kind: 'text', required: false },
      answer: a.answer,
      orphaned: true,
    }))
  return [...rows, ...orphans]
}

/** Only answered rows are stored; whitespace-only answers count as unanswered. */
export function answersFromRows(rows: AnswerRow[]): ScreeningAnswer[] {
  return rows
    .map((r) => ({ question_id: r.question.id, answer: r.answer.trim() }))
    .filter((a) => a.answer !== '')
}
