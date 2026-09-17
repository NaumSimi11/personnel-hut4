/**
 * The welcome note (plan 050): the database builds the text; these shape
 * the card — which addresses can be offered and when it last went.
 */
export type WelcomeNote = {
  subject: string
  text: string
  lines: string[]
  personal_email: string | null
  work_email: string | null
  sent_at: string | null
  sent_to: string | null
  policies: { title: string; summary: string | null }[]
  first_day: Record<string, string>
}

export type AddressChoice = { key: 'personal' | 'work'; label: string }

export function addressChoices(n: { personal_email: string | null; work_email: string | null }): AddressChoice[] {
  return [
    ...(n.personal_email ? [{ key: 'personal' as const, label: `Personal email · ${n.personal_email}` }] : []),
    ...(n.work_email ? [{ key: 'work' as const, label: `Work email · ${n.work_email}` }] : []),
  ]
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

export function sentLine(sentAt: string | null, sentTo: string | null): string {
  if (!sentAt) return 'Not sent yet.'
  const d = new Date(sentAt)
  const day = `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`
  return `Last sent ${day} to the ${sentTo === 'work' ? 'work' : 'personal'} email.`
}
