import { describe, expect, it } from 'vitest'
import { buildManagerEmail, managerEventMatches } from './hiringEmails.js'

const input = {
  role: 'Dispatcher <Senior>',
  company: 'Praedium',
  requester: 'Fiona Finance',
  approver: 'Alex Director',
  targetStart: '2027-01-11',
  url: 'https://people.hut4.com/hiring',
}

describe('buildManagerEmail', () => {
  it('tells the manager they are assigned and that nothing starts until approval', () => {
    const mail = buildManagerEmail('assigned', input)
    expect(mail.subject).toBe('You are the hiring manager for Dispatcher <Senior>')
    expect(mail.html).toContain('&lt;Senior&gt;')
    expect(mail.html).toContain('Awaiting approval')
    expect(mail.html).toContain('does not authorize recruitment')
    expect(mail.html).toContain('Target employee start: <strong>2027-01-11</strong>')
    expect(mail.html).toContain('not a deadline for you')
    expect(mail.html).not.toMatch(/[Dd]ueb/)
  })
  it('says recruitment can proceed once approved, with the approver', () => {
    const mail = buildManagerEmail('approved', input)
    expect(mail.subject).toBe('Recruitment can proceed: Dispatcher <Senior>')
    expect(mail.html).toContain('Alex Director')
    expect(mail.html).toContain('Prepare the role')
  })
  it('shows a missing target start as not set', () => {
    expect(buildManagerEmail('assigned', { ...input, targetStart: null }).html).toContain('Target employee start: <strong>Not set</strong>')
  })
})

describe('managerEventMatches', () => {
  it('only mails what the record shows', () => {
    expect(managerEventMatches('assigned', { status: 'submitted', hiring_manager_id: 'm' })).toBe(true)
    expect(managerEventMatches('assigned', { status: 'approved', hiring_manager_id: 'm' })).toBe(false)
    expect(managerEventMatches('approved', { status: 'approved', hiring_manager_id: 'm' })).toBe(true)
    expect(managerEventMatches('approved', { status: 'approved', hiring_manager_id: null })).toBe(false)
  })
})
