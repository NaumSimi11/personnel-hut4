import { describe, expect, it } from 'vitest'
import { friendlyTransferError, transferInput } from './transfer'

describe('transferInput', () => {
  it('needs a target company and a date; title and type are optional', () => {
    expect(transferInput.safeParse({ companyId: 'c', effectiveDate: '2026-10-01', jobTitle: ' Lead ', employmentTypeKey: '', reason: '' }).success).toBe(true)
    expect(transferInput.safeParse({ companyId: '', effectiveDate: '2026-10-01', jobTitle: '', employmentTypeKey: '', reason: '' }).success).toBe(false)
    expect(transferInput.safeParse({ companyId: 'c', effectiveDate: '', jobTitle: '', employmentTypeKey: '', reason: '' }).success).toBe(false)
  })
})

describe('friendlyTransferError', () => {
  it('names the missing capability side and passes rule messages through', () => {
    expect(friendlyTransferError('Transferring needs employment.edit in the target company.')).toMatch(/target company/)
    expect(friendlyTransferError('The transfer date must be after the employment started (2024-01-01).')).toMatch(/2024-01-01/)
  })
})
