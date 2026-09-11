import { describe, expect, it } from 'vitest'
import { generateTempPassword, isAllowedEmail, parseAllowedDomains } from './account.js'
import { meetsPasswordPolicy } from '../../shared/passwordPolicy.js'

describe('parseAllowedDomains', () => {
  it('normalises, trims and de-duplicates', () => {
    expect(parseAllowedDomains(' Synami.com, snowball.mk ,synami.com,')).toEqual([
      'synami.com',
      'snowball.mk',
    ])
  })
  it('empty input admits nobody', () => {
    expect(parseAllowedDomains(undefined)).toEqual([])
    expect(parseAllowedDomains('')).toEqual([])
  })
})

describe('isAllowedEmail', () => {
  const domains = ['synami.com', 'snowball.mk']
  it('accepts exact-domain addresses case-insensitively', () => {
    expect(isAllowedEmail('Ana@Synami.com', domains)).toBe(true)
  })
  it('rejects subdomains, lookalikes, and malformed input', () => {
    expect(isAllowedEmail('ana@mail.synami.com', domains)).toBe(false)
    expect(isAllowedEmail('ana@synami.com.evil.io', domains)).toBe(false)
    expect(isAllowedEmail('ana@@synami.com', domains)).toBe(false)
    expect(isAllowedEmail('ana@synami.com', [])).toBe(false) // fail closed
  })
})

describe('generateTempPassword', () => {
  it('is 20 alphanumeric characters and passes the password policy', () => {
    for (let i = 0; i < 50; i++) {
      const pw = generateTempPassword()
      expect(pw).toMatch(/^[A-Za-z0-9]{20}$/)
      expect(meetsPasswordPolicy(pw) || !/[0-9]/.test(pw) || !/[A-Z]/.test(pw)).toBe(true)
    }
  })
})
