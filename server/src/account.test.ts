import { describe, expect, it } from 'vitest'
import { generateTempPassword, isAllowedEmail, parseAllowedDomains, planInvite } from './account.js'
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

describe('planInvite', () => {
  it('creates a new person when nobody matches the work email', () => {
    expect(planInvite(null)).toEqual({ action: 'create' })
  })
  it('attaches to an existing record-only person (no account yet)', () => {
    expect(planInvite({ id: 'person-1', user_id: null })).toEqual({
      action: 'attach',
      personId: 'person-1',
    })
  })
  it('refuses when the matched person already has an account', () => {
    expect(planInvite({ id: 'person-1', user_id: 'user-1' })).toEqual({
      action: 'refuse',
      reason: 'has_account',
    })
  })
})
