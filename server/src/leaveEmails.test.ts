import { describe, expect, it } from 'vitest'
import { NotifyThrottle, buildLeaveEmail, eventMatchesRequest, leaveRecipients } from './leaveEmails.js'

const request = {
  personName: 'Ana Ilievska',
  personEmail: 'ana@synami.com',
  companyName: 'Synami',
  leaveType: 'Annual leave',
  startDate: '2027-03-01',
  endDate: '2027-03-05',
  workingDays: 5,
  remaining: 12,
  note: 'Skiing <b>trip</b>',
}

describe('buildLeaveEmail', () => {
  it('tells HR about a new request, escaping the note', () => {
    const mail = buildLeaveEmail('submitted', request)
    expect(mail.subject).toBe('New leave request · Ana Ilievska')
    expect(mail.html).toContain('Synami')
    expect(mail.html).toContain('5 working days')
    expect(mail.html).toContain('&lt;b&gt;trip&lt;/b&gt;')
    expect(mail.html).not.toContain('<b>trip')
  })
  it('tells the person about a decision with what is left', () => {
    expect(buildLeaveEmail('approved', request).subject).toBe('Leave request approved · Ana Ilievska')
    expect(buildLeaveEmail('approved', request).html).toContain('12 days')
    expect(buildLeaveEmail('rejected', { ...request, decisionNote: 'Busy week' }).html).toContain('Busy week')
  })
  it('handles one working day and cancellation asks', () => {
    expect(buildLeaveEmail('submitted', { ...request, workingDays: 1 }).html).toContain('(1 working day)')
    expect(buildLeaveEmail('cancellation_asked', request).subject).toBe('Asks to cancel leave · Ana Ilievska')
  })
})

describe('leaveRecipients', () => {
  it('sends submissions and asks to the approvers, decisions to the person', () => {
    const approvers = ['hr@hut4.com', 'director@synami.com']
    expect(leaveRecipients('submitted', request, approvers)).toEqual(approvers)
    expect(leaveRecipients('cancellation_asked', request, approvers)).toEqual(approvers)
    expect(leaveRecipients('approved', request, approvers)).toEqual(['ana@synami.com'])
    expect(leaveRecipients('rejected', { ...request, personEmail: null }, approvers)).toEqual([])
  })
})

describe('eventMatchesRequest', () => {
  it('only mails what the record says happened', () => {
    const base = { status: 'pending', cancellation_requested_at: null as string | null, cancellation_declined_at: null as string | null }
    expect(eventMatchesRequest('submitted', base)).toBe(true)
    expect(eventMatchesRequest('approved', base)).toBe(false)
    expect(eventMatchesRequest('approved', { ...base, status: 'approved' })).toBe(true)
    expect(eventMatchesRequest('rejected', { ...base, status: 'rejected' })).toBe(true)
    expect(eventMatchesRequest('cancellation_asked', { ...base, status: 'approved', cancellation_requested_at: '2027-01-01T00:00:00Z' })).toBe(true)
    expect(eventMatchesRequest('cancellation_asked', { ...base, status: 'approved', cancellation_requested_at: '2027-01-01T00:00:00Z', cancellation_declined_at: '2027-01-02T00:00:00Z' })).toBe(false)
  })
})

describe('NotifyThrottle', () => {
  it('lets one mail per request and event through per window', () => {
    let now = 1000
    const t = new NotifyThrottle(60_000, () => now)
    expect(t.allow('r1', 'submitted')).toBe(true)
    expect(t.allow('r1', 'submitted')).toBe(false)
    expect(t.allow('r1', 'approved')).toBe(true)
    now += 61_000
    expect(t.allow('r1', 'submitted')).toBe(true)
  })
})
