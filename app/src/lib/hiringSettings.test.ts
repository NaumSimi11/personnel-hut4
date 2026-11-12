import { describe, expect, it } from 'vitest'
import { previewTemplate, reasonKey, settingProblem, templateProblem } from './hiringSettings'

describe('hiring settings', () => {
  it('takes whole numbers in range, blank meaning the default', () => {
    expect(settingProblem('')).toBeNull()
    expect(settingProblem('5')).toBeNull()
    expect(settingProblem('-1')).toMatch(/whole number/)
    expect(settingProblem('2.5')).toMatch(/whole number/)
  })
  it('previews placeholders with sample values', () => {
    expect(previewTemplate('Dear {candidate}, {job} at {company} {nope}')).toBe('Dear Ana Kova, Designer at Hut4 {nope}')
  })
  it('needs a subject and a body', () => {
    expect(templateProblem('', 'x')).toMatch(/subject/)
    expect(templateProblem('Hi', ' ')).toMatch(/Write/)
    expect(templateProblem('Hi', 'Body')).toBeNull()
  })
  it('makes a reason key from its label', () => {
    expect(reasonKey('Failed the test!')).toBe('failed_the_test')
    expect(reasonKey('2nd choice')).toBe('r_2nd_choice')
  })
})
