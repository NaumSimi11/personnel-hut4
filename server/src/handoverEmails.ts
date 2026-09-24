/**
 * The mail for one handover send (plan 048): a small table with exactly
 * the fields the database put on the row — nothing is added here, so what
 * a recipient may see was decided before the mail existed.
 */
export type HandoverField = { label: string; value: string }
export type HandoverSendLike = {
  event: string
  recipient_label: string
  fields: Record<string, HandoverField>
  stripped: string[]
}

const SUBJECTS: Record<string, string> = {
  hire_confirmed: 'New hire',
  onboarding_finished: 'Onboarding finished',
  departure_scheduled: 'Departure scheduled',
  marked_former: 'Employment ended',
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string)
}

export function renderHandoverEmail(send: HandoverSendLike): { subject: string; html: string } {
  const who = send.fields.name?.value ?? 'a colleague'
  const subject = `${SUBJECTS[send.event] ?? 'Handover'}: ${who}`
  const rows = Object.values(send.fields)
    .map((f) => `<tr><td>${escapeHtml(f.label)}</td><td><strong>${escapeHtml(f.value)}</strong></td></tr>`)
    .join('\n')
  return {
    subject,
    html: [
      `<p><strong>${escapeHtml(subject)}</strong></p>`,
      `<p>For ${escapeHtml(send.recipient_label)}, from PeopleOS.</p>`,
      `<table cellpadding="6" style="border-collapse:collapse;font-size:14px">${rows}</table>`,
      `<p style="color:#6b7a72;font-size:12px">You receive this because you are on the handover list for this event. Reply to HR if something is missing.</p>`,
    ].join('\n'),
  }
}
