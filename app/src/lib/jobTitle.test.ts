import { describe, expect, it } from 'vitest'
import { cleanJobTitle, jobTitleProblem } from './jobTitle'

describe('cleanJobTitle', () => {
  it('trims the ends and collapses the middle', () => {
    expect(cleanJobTitle('   Frontend    Dev  ')).toBe('Frontend Dev')
  })

  it('leaves an ordinary title alone', () => {
    expect(cleanJobTitle('Head of People')).toBe('Head of People')
  })
})

describe('jobTitleProblem', () => {
  const ok = (title: string) => expect(jobTitleProblem(title)).toBeNull()
  const bad = (title: string) => expect(jobTitleProblem(title)).not.toBeNull()

  it('accepts the titles people actually use', () => {
    ok('Frontend Dev')
    ok('Head of People')
    ok('Senior Software Engineer')
    ok('Développeur')
    ok('Програмер') // Cyrillic, as this holding writes them
  })

  it('accepts short abbreviations, which have no vowels by nature', () => {
    ok('QA')
    ok('HR')
    ok('CTO')
    ok('CFO')
  })

  it('rejects a keyboard mash', () => {
    bad('dvsdv') // the one sitting in production right now
    bad('asdfgh')
    bad('qwerty')
  })

  it('rejects one character repeated', () => {
    bad('aaaa')
    bad('....')
  })

  it('rejects a title with no letter in it', () => {
    bad('12345')
    bad('---')
  })

  it('rejects something too short to be a role', () => {
    bad('a')
    bad('')
    bad('   ')
  })

  it('judges the cleaned title, not the raw one', () => {
    ok('  Frontend   Dev  ')
  })

  it('explains itself in words a person can act on', () => {
    expect(jobTitleProblem('dvsdv')).toBe('That does not look like a job title.')
    expect(jobTitleProblem('a')).toBe('Enter a job title.')
  })
})
