import { describe, expect, it } from 'vitest'
import { answersFromRows, mergeAnswers, type ScreeningAnswer } from './screeningAnswers'
import type { ScreeningQuestion } from './jobWorkspace'

const questions: ScreeningQuestion[] = [
  { id: 'q1', prompt: 'Why this role?', kind: 'text', required: true },
  { id: 'q2', prompt: 'Eligible to work here?', kind: 'yes_no', required: true },
  { id: 'q3', prompt: 'Notice period', kind: 'choice', required: false, options: ['Immediate', '1 month'] },
]

describe('mergeAnswers', () => {
  it('pairs every job question with its answer, empty when unanswered', () => {
    const rows = mergeAnswers(questions, [{ question_id: 'q2', answer: 'yes' }])
    expect(rows.map((r) => [r.question.id, r.answer])).toEqual([
      ['q1', ''],
      ['q2', 'yes'],
      ['q3', ''],
    ])
  })

  it('keeps answers to questions the job no longer asks, flagged as orphaned', () => {
    const rows = mergeAnswers(questions, [{ question_id: 'old', answer: 'Something' }])
    const orphan = rows.find((r) => r.question.id === 'old')
    expect(orphan?.orphaned).toBe(true)
    expect(orphan?.answer).toBe('Something')
    expect(orphan?.question.prompt).toBe('Question no longer on the job')
  })

  it('tolerates a stored value that is not a list', () => {
    expect(mergeAnswers(questions, null).length).toBe(3)
    expect(mergeAnswers(questions, { not: 'a list' }).length).toBe(3)
  })
})

describe('answersFromRows', () => {
  it('writes back only non-empty answers, trimmed', () => {
    const rows = mergeAnswers(questions, [{ question_id: 'q1', answer: '  Growth  ' }])
    const out: ScreeningAnswer[] = answersFromRows(rows)
    expect(out).toEqual([{ question_id: 'q1', answer: 'Growth' }])
  })
})
