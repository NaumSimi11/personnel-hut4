import { describe, expect, it } from 'vitest'
import {
  documentInput,
  documentObjectPath,
  validateDocumentFile,
  visibilityLabel,
  visibilityOptions,
} from './documents'

describe('validateDocumentFile', () => {
  it('accepts PDF, Word and images up to 20 MB', () => {
    expect(validateDocumentFile({ type: 'application/pdf', size: 1000, name: 'a.pdf' })).toBeNull()
    expect(validateDocumentFile({ type: 'image/png', size: 1000, name: 'a.png' })).toBeNull()
    expect(validateDocumentFile({ type: 'text/plain', size: 10, name: 'a.txt' })).toMatch(/PDF/)
    expect(validateDocumentFile({ type: 'application/pdf', size: 21 * 1024 * 1024, name: 'a.pdf' })).toMatch(/20 MB/)
  })
})

describe('documentObjectPath', () => {
  it('nests under the company and the person, or "company" for company documents', () => {
    expect(documentObjectPath('c1', 'p1', 'd1', 'application/pdf')).toBe('c1/p1/d1.pdf')
    expect(documentObjectPath('c1', null, 'd1', 'image/jpeg')).toBe('c1/company/d1.jpg')
  })
})

describe('documentInput', () => {
  it('requires a title and category', () => {
    expect(documentInput.safeParse({ title: ' Contract ', categoryKey: 'employment_agreement', visibility: 'person_and_hr', note: '' }).success).toBe(true)
    expect(documentInput.safeParse({ title: 'C', categoryKey: 'employment_agreement', visibility: 'person_and_hr', note: '' }).success).toBe(false)
    expect(documentInput.safeParse({ title: 'Contract', categoryKey: '', visibility: 'person_and_hr', note: '' }).success).toBe(false)
    expect(documentInput.safeParse({ title: 'Contract', categoryKey: 'x', visibility: 'everyone', note: '' }).success).toBe(false)
  })
})

describe('visibility', () => {
  it('offers person choices for person documents and company choices otherwise', () => {
    expect(visibilityOptions('person').map((o) => o.key)).toEqual(['person_and_hr', 'hr_only'])
    expect(visibilityOptions('company').map((o) => o.key)).toEqual(['company_public', 'hr_only'])
    expect(visibilityLabel('hr_only')).toBe('HR only')
    expect(visibilityLabel('company_public')).toBe('Everyone in the company')
  })
})
