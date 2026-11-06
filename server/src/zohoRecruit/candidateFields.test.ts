import { describe, expect, it } from 'vitest'
import type { CsvRow } from './csv.js'
import { candidateEmail, candidatePhone, candidateSkills } from './candidateFields.js'

const cand = (fields: Record<string, string>): CsvRow => ({ 'Candidate ID': 'ZR_1_CAND', ...fields })

describe('candidate fields', () => {
  it('email: a malformed address goes to custom.links.raw_email; the secondary is kept', () => {
    expect(candidateEmail(cand({ Email: ' Test.One@Example.test ' }))).toEqual({ email: 'test.one@example.test', links: {} })
    expect(candidateEmail(cand({ Email: 'not-an-email' }))).toEqual({ email: null, links: { raw_email: 'not-an-email' } })
    expect(candidateEmail(cand({ Email: '', 'Secondary Email': 'alt@example.test' })))
      .toEqual({ email: null, links: { secondary_email: 'alt@example.test' } })
  })

  it('phone: Mobile first, then Phone; the other one is kept in custom.links', () => {
    expect(candidatePhone(cand({ Mobile: '+389 70 123 456' }))).toEqual({ phone: '+389 70 123 456', links: {} })
    expect(candidatePhone(cand({ Phone: '070 123 456' }))).toEqual({ phone: '070 123 456', links: {} })
    expect(candidatePhone(cand({ Mobile: '070', Phone: '071' }))).toEqual({ phone: '070', links: { phone: '071' } })
    expect(candidatePhone(cand({}))).toEqual({ phone: null, links: {} })
  })

  it('skills: split on the comma and trimmed; an item over 60 characters is not a skill', () => {
    expect(candidateSkills('Vue, TypeScript ,  SQL')).toEqual({ skills: ['Vue', 'TypeScript', 'SQL'], dropped: [] })
    const long = 'x'.repeat(61)
    expect(candidateSkills(`Vue, ${long}`)).toEqual({ skills: ['Vue'], dropped: [long] })
    expect(candidateSkills('')).toEqual({ skills: [], dropped: [] })
  })
})
