import { describe, expect, it } from 'vitest'
import { renderNotificationEmail } from './notificationEmails.js'

describe('renderNotificationEmail', () => {
  it('turns a notification row into a plain, escaped mail with a link into the app', () => {
    const mail = renderNotificationEmail(
      { title: 'Leave request from Ana <Ilievska>', body: 'Annual leave · 01 Mar → 05 Mar 2027 · 5 working days — "Ski & sun"', link: '/leave?tab=requests', kind: 'leave.requested' },
      'https://people.hut4.com/',
    )
    expect(mail.subject).toBe('Leave request from Ana <Ilievska>')
    expect(mail.html).toContain('Ana &lt;Ilievska&gt;')
    expect(mail.html).toContain('&quot;Ski &amp; sun&quot;')
    expect(mail.html).toContain('href="https://people.hut4.com/leave?tab=requests"')
    expect(mail.html).toContain('Open in PeopleOS')
  })
  it('keeps the paragraphs and lines of a multi-line body', () => {
    const mail = renderNotificationEmail({ title: 'Welcome', body: 'Dear Wel,\n\nWelcome.\nSee you soon,\nHR', link: null, kind: 'welcome.note' }, null)
    expect(mail.html).toContain('<p>Dear Wel,</p>')
    expect(mail.html).toContain('<p>Welcome.<br>See you soon,<br>HR</p>')
  })
  it('copes without a body or a link', () => {
    const mail = renderNotificationEmail({ title: 'Hi', body: null, link: null, kind: 'x' }, null)
    expect(mail.html).not.toContain('href')
    expect(mail.html).toContain('<p><strong>Hi</strong></p>')
  })
})
