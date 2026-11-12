import { describe, expect, it } from 'vitest'
import { renderCandidateEmail } from './candidateEmails.js'

const data = { candidate: 'Ana <Kova>', job: 'Designer & Illustrator', company: 'Hut4' }

describe('renderCandidateEmail', () => {
  it('confirms an application, naming the role and the company', () => {
    const mail = renderCandidateEmail('received', data)
    expect(mail.subject).toBe('We received your application: Designer & Illustrator')
    expect(mail.html).toContain('Dear Ana &lt;Kova&gt;,')
    expect(mail.html).toContain('Designer &amp; Illustrator')
    expect(mail.html).toContain('The Hut4 team')
  })

  it('declines politely without giving a reason', () => {
    const mail = renderCandidateEmail('rejected', data)
    expect(mail.subject).toBe('Your application: Designer & Illustrator at Hut4')
    expect(mail.html).toContain('not to move forward')
    expect(mail.html).not.toMatch(/reason|unqualified|rejected_/i)
  })

  it('confirms a withdrawal and never reads as a rejection', () => {
    const mail = renderCandidateEmail('withdrawn', data)
    expect(mail.subject).toBe('Your application has been withdrawn: Designer & Illustrator')
    expect(mail.html).toContain('withdrawn')
    expect(mail.html).not.toContain('not to move forward')
  })

  it('copes with missing names', () => {
    const mail = renderCandidateEmail('received', {})
    expect(mail.html).toContain('Dear candidate,')
    expect(mail.subject).toBe('We received your application: the role')
    expect(mail.html).toContain('at our company')
    expect(mail.html).toContain('The hiring team')
  })
})
