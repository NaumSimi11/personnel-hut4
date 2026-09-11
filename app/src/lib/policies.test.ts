import { describe, expect, it } from 'vitest'
import { acknowledgementState, policyInput, policyObjectPath, requestInput, requestStatusLabel } from './policies'

describe('requestInput', () => {
  it('needs a category; due date and note are optional', () => {
    expect(requestInput.safeParse({ categoryKey: 'identification', dueDate: '', note: '' }).success).toBe(true)
    expect(requestInput.safeParse({ categoryKey: '', dueDate: '2026-10-01', note: '' }).success).toBe(false)
    expect(requestInput.safeParse({ categoryKey: 'identification', dueDate: '10/01/2026', note: '' }).success).toBe(false)
  })
})

describe('requestStatusLabel', () => {
  it('names each state for people', () => {
    expect(requestStatusLabel('pending')).toBe('Waiting for the document')
    expect(requestStatusLabel('needs_correction')).toBe('Needs a correction')
    expect(requestStatusLabel('accepted')).toBe('Accepted')
  })
})

describe('policyInput / policyObjectPath', () => {
  it('requires a title and nests the file under the company or "holding"', () => {
    expect(policyInput.safeParse({ title: ' Code of conduct ', summary: '' }).success).toBe(true)
    expect(policyInput.safeParse({ title: 'C', summary: '' }).success).toBe(false)
    expect(policyObjectPath('c1', 'p1', 'application/pdf', 'f1')).toBe('c1/p1/f1.pdf')
    expect(policyObjectPath(null, 'p1', 'application/msword', 'f2')).toBe('holding/p1/f2.doc')
  })
})

describe('acknowledgementState', () => {
  const policy = { id: 'p1', version: 2, status: 'published' }
  it('counts only the current version as acknowledged', () => {
    expect(acknowledgementState(policy, [{ policy_id: 'p1', version: 1 }])).toBe('outdated')
    expect(acknowledgementState(policy, [{ policy_id: 'p1', version: 2 }])).toBe('acknowledged')
    expect(acknowledgementState(policy, [])).toBe('pending')
  })
})
