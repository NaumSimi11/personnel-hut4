import { describe, expect, it } from 'vitest'
import { CHECK_ANSWERS, answerInput, checkProgress, checkLine, needsFollowUp } from './equipmentCheck'

describe('the yearly equipment check (24 Nov)', () => {
  it('offers three answers, each with a label an employee understands', () => {
    expect(CHECK_ANSWERS.map((a) => a.key)).toEqual(['have', 'missing', 'issue'])
    expect(CHECK_ANSWERS.find((a) => a.key === 'have')?.label).toBe('I still have and use it')
  })

  it('needs no note to confirm, but a note to report it missing or wrong', () => {
    expect(answerInput.safeParse({ answer: 'have', note: '' }).success).toBe(true)
    expect(answerInput.safeParse({ answer: 'missing', note: '' }).success).toBe(false)
    expect(answerInput.safeParse({ answer: 'issue', note: 'ab' }).success).toBe(false)
    expect(answerInput.safeParse({ answer: 'issue', note: 'Screen cracked' }).success).toBe(true)
    expect(answerInput.safeParse({ answer: 'lost', note: 'x' }).success).toBe(false)
    expect(answerInput.safeParse({ answer: 'missing', note: 'x'.repeat(501) }).success).toBe(false)
  })

  it('counts the answers, the open items, and what still needs following up', () => {
    const items = [
      { answer: 'have', followed_up_at: null },
      { answer: 'missing', followed_up_at: null },
      { answer: 'issue', followed_up_at: '2026-11-25' },
      { answer: null, followed_up_at: null },
      { answer: null, followed_up_at: null },
    ]
    expect(checkProgress(items)).toEqual({ total: 5, have: 1, missing: 1, issue: 1, open: 2, toFollowUp: 1 })
    expect(needsFollowUp(items[1])).toBe(true)
    expect(needsFollowUp(items[2])).toBe(false)
    expect(needsFollowUp(items[0])).toBe(false)
  })

  it('names the check and its deadline', () => {
    expect(checkLine({ name: 'Equipment check 2026', deadline: '2026-12-15' })).toBe('Equipment check 2026 · answer by 15 Dec 2026')
  })
})
