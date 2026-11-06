import type { CsvRow } from './csv.js'
import { splitList } from './csv.js'

/**
 * A Zoho candidate's contact fields and skills, as the Candidate-Job View
 * import reads them (jobView.ts). An unreadable email is kept aside in
 * `links`, never guessed into the email column.
 */

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/
const SKILL_MAX = 60

const blank = (v: string | null | undefined): string | null => {
  const t = (v ?? '').trim()
  return t === '' ? null : t
}

export function candidateEmail(r: CsvRow): { email: string | null; links: Record<string, string> } {
  const links: Record<string, string> = {}
  const raw = blank(r.Email)
  const email = raw && EMAIL.test(raw) ? raw.toLowerCase() : null
  if (raw && !email) links.raw_email = raw
  const secondary = blank(r['Secondary Email'])
  if (secondary) links.secondary_email = secondary
  return { email, links }
}

export function candidatePhone(r: CsvRow): { phone: string | null; links: Record<string, string> } {
  const mobile = blank(r.Mobile)
  const phone = blank(r.Phone)
  if (mobile) return { phone: mobile, links: phone ? { phone } : {} }
  return { phone, links: {} }
}

export function candidateSkills(value: string): { skills: string[]; dropped: string[] } {
  const items = splitList(value)
  return { skills: items.filter((s) => s.length <= SKILL_MAX), dropped: items.filter((s) => s.length > SKILL_MAX) }
}
