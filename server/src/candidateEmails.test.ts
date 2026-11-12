import { describe, expect, it } from 'vitest'
import { fillPlaceholders, renderCandidateEmail, renderFromTemplate } from './candidateEmails.js'

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

describe('offer emails', () => {
  const token = 'a'.repeat(64)
  it('carries the terms and the private link', () => {
    const mail = renderCandidateEmail('offer', { ...data, token, salary: '42000', currency: 'EUR', start_date: '2027-01-04', expires_on: '2026-11-20' }, 'https://people.hut4.com/')
    expect(mail.subject).toBe('Your offer: Designer & Illustrator at Hut4')
    expect(mail.html).toContain('Salary: 42,000 EUR. Start date: 2027-01-04.')
    expect(mail.html).toContain('Please answer by 2026-11-20.')
    expect(mail.html).toContain(`href="https://people.hut4.com/offer/${token}"`)
  })
  it('leaves the link out without a base URL or a proper token', () => {
    expect(renderCandidateEmail('offer', { ...data, token }, null).html).not.toContain('href')
    expect(renderCandidateEmail('offer_reminder', { ...data, token: 'bad' }, 'https://x.test').html).not.toContain('href')
  })
})

describe('HR templates', () => {
  it('fills the placeholders and keeps paragraphs, escaped', () => {
    const mail = renderFromTemplate('rejected', { subject: 'About {job}', body: 'Hi {candidate},\n\nThanks from {company}.\nBest' }, data)
    expect(mail.subject).toBe('About Designer & Illustrator')
    expect(mail.html).toBe('<p>Hi Ana &lt;Kova&gt;,</p>\n<p>Thanks from Hut4.<br>Best</p>')
  })
  it('always ends an offer with its link', () => {
    const token = 'b'.repeat(64)
    const mail = renderFromTemplate('offer', { subject: 'Offer', body: 'Salary {salary}' }, { ...data, token, salary: 1000, currency: 'EUR' }, 'https://x.test')
    expect(mail.html).toContain('Salary 1,000 EUR')
    expect(mail.html).toContain(`https://x.test/offer/${token}`)
  })
  it('leaves unknown braces alone', () => {
    expect(fillPlaceholders('{nope} {job}', data)).toBe('{nope} Designer & Illustrator')
  })
})
