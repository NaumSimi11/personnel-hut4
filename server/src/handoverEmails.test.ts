import { describe, expect, it } from 'vitest'
import { renderHandoverEmail } from './handoverEmails.js'

describe('renderHandoverEmail', () => {
  it('renders one row per field the send carries, escaped, with the event in the subject', () => {
    const mail = renderHandoverEmail({
      event: 'hire_confirmed',
      recipient_label: 'Accountant',
      fields: {
        name: { label: 'Full name', value: 'Ana <Ilievska>' },
        bank_account: { label: 'Bank account', value: 'NLB · 210000000000888' },
      },
      stripped: ['Salary'],
    })
    expect(mail.subject).toBe('New hire: Ana <Ilievska>')
    expect(mail.html).toContain('<td>Full name</td>')
    expect(mail.html).toContain('Ana &lt;Ilievska&gt;')
    expect(mail.html).toContain('210000000000888')
    expect(mail.html).not.toContain('Salary')
    expect(mail.html).not.toContain('national')
  })

  it('names the other events and copes with a send that has no name field', () => {
    expect(renderHandoverEmail({ event: 'departure_scheduled', recipient_label: 'IT', fields: { position: { label: 'Position', value: 'Clerk' } }, stripped: [] }).subject).toBe('Departure scheduled: a colleague')
    expect(renderHandoverEmail({ event: 'marked_former', recipient_label: 'Accountant', fields: { name: { label: 'Full name', value: 'Bo' } }, stripped: [] }).subject).toBe('Employment ended: Bo')
    expect(renderHandoverEmail({ event: 'onboarding_finished', recipient_label: 'IT', fields: { name: { label: 'Full name', value: 'Bo' } }, stripped: [] }).subject).toBe('Onboarding finished: Bo')
  })
})
