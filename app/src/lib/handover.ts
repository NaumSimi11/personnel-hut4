/**
 * The handover (plan 048): who is told what when someone joins or leaves,
 * and whether it went. The database (migration 0041) builds every send and
 * decides what a recipient may receive; these helpers shape the settings
 * form and the traffic light.
 */

export type HandoverFieldDef = { key: string; label: string; sensitivity: 'plain' | 'personal' | 'pay' }

export type HandoverRecipient = {
  id: string
  company_id: string | null
  label: string
  kind: 'role' | 'person' | 'email'
  role_key: string | null
  person_id: string | null
  email: string | null
  events: string[]
  fields: string[]
  trusted: boolean
  active: boolean
}

export type HandoverSend = {
  id: string
  event: string
  recipient_label: string
  to_email: string | null
  fields: Record<string, { label: string; value: string }>
  stripped: string[]
  missing: string[]
  status: string
  error: string | null
  sent_at: string | null
  marked_by: string | null
}

export const EVENTS = [
  { key: 'hire_confirmed', label: 'new hire' },
  { key: 'onboarding_finished', label: 'onboarding finished' },
  { key: 'departure_scheduled', label: 'departure scheduled' },
  { key: 'marked_former', label: 'employment ended' },
] as const

export function eventLabel(key: string): string {
  return EVENTS.find((e) => e.key === key)?.label ?? key
}

export type Light = 'green' | 'red' | 'grey'

export function light(status: string): Light {
  if (status === 'sent' || status === 'manual') return 'green'
  if (status === 'failed' || status === 'missing') return 'red'
  return 'grey'
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

function day(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`
}

export function sendLine(s: HandoverSend): string {
  switch (s.status) {
    case 'sent':
      return `Sent ${day(s.sent_at)}`.trim()
    case 'manual':
      return `Sent by hand ${day(s.sent_at)}`.trim()
    case 'failed':
      return `Failed${s.error ? ` — ${s.error}` : ''}`
    case 'missing':
      return `Not sent — missing ${s.missing.join(', ')}`
    case 'cancelled':
      return 'Cancelled with the departure'
    default:
      return 'Queued for sending'
  }
}

/** May this viewer put this field on this recipient for this company? Mirrors save_handover_recipient. */
export function canPlaceField(
  field: HandoverFieldDef,
  recipient: { trusted: boolean },
  viewer: { can: (companyId: string, capability: string) => boolean },
  companyId: string,
): boolean {
  if (field.sensitivity === 'plain') return true
  if (!recipient.trusted) return false
  return viewer.can(companyId, field.sensitivity === 'pay' ? 'salary.view' : 'personal.view')
}

export function recipientTarget(
  r: { kind: string; role_key: string | null; person_id: string | null; email: string | null },
  roles: Record<string, string>,
  people: Record<string, string>,
): string {
  if (r.kind === 'role') return r.role_key === 'manager' ? "The person's manager" : (roles[r.role_key ?? ''] ?? r.role_key ?? 'Role')
  if (r.kind === 'person') return people[r.person_id ?? ''] ?? 'Colleague'
  return r.email || 'Address not set'
}

export function recipientSummary(r: { events: string[]; fields: string[] }, catalogue: HandoverFieldDef[]): string {
  const when = r.events.map(eventLabel).join(', ') || 'never'
  const what = r.fields.map((k) => catalogue.find((f) => f.key === k)?.label ?? k).join(', ') || 'nothing'
  return `On ${when} · ${what}`
}

export function messageForHandover(error: { code?: string; message: string }): string {
  if (error.code === '42501') return error.message
  if (/row-level security/i.test(error.message)) return 'You do not have permission to change the handover.'
  return error.message
}
