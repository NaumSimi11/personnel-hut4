/**
 * Hiring settings HR edits (0109, 0110): the time limits, the candidate
 * emails' wording and the reusable templates. The database holds the rule
 * (ranges, who may write); this names things and checks input first.
 */
export type SettingKey =
  | 'first_response_days' | 'offer_expiry_days' | 'offer_warn_days' | 'feedback_remind_hours'
  | 'feedback_escalate_hours' | 'source_credit_days' | 'approval_overdue_days' | 'approval_escalate_days'

export const SETTINGS: ReadonlyArray<{ key: SettingKey; label: string; unit: 'days' | 'hours'; fallback: number }> = [
  { key: 'first_response_days', label: 'Alert when nobody has replied to an applicant after', unit: 'days', fallback: 3 },
  { key: 'offer_expiry_days', label: 'A sent offer expires after', unit: 'days', fallback: 7 },
  { key: 'offer_warn_days', label: 'Remind about an offer this long before it expires', unit: 'days', fallback: 2 },
  { key: 'feedback_remind_hours', label: 'Remind interviewers to score after', unit: 'hours', fallback: 24 },
  { key: 'feedback_escalate_hours', label: 'Tell the hiring manager about missing scores after', unit: 'hours', fallback: 48 },
  { key: 'approval_overdue_days', label: 'Remind approvers of a waiting step after', unit: 'days', fallback: 3 },
  { key: 'approval_escalate_days', label: 'Tell the company HR contact about a stuck approval after', unit: 'days', fallback: 7 },
  { key: 'source_credit_days', label: 'The earliest source keeps the credit for', unit: 'days', fallback: 90 },
]

export function settingProblem(raw: string): string | null {
  if (!raw.trim()) return null
  const n = Number(raw)
  if (!Number.isInteger(n) || n < 0 || n > 3650) return 'Use a whole number from 0 to 3650.'
  return null
}

export type EmailKind = 'received' | 'rejected' | 'withdrawn' | 'offer' | 'offer_reminder'
export const EMAIL_KINDS: ReadonlyArray<{ kind: EmailKind; label: string }> = [
  { kind: 'received', label: 'Application received' },
  { kind: 'rejected', label: 'Rejection' },
  { kind: 'withdrawn', label: 'Withdrawal confirmed' },
  { kind: 'offer', label: 'The offer (the link is added at the end)' },
  { kind: 'offer_reminder', label: 'Offer reminder (the link is added at the end)' },
]
export const PLACEHOLDERS = ['{candidate}', '{job}', '{company}', '{salary}', '{start_date}', '{expires_on}'] as const

const SAMPLE: Record<string, string> = {
  candidate: 'Ana Kova', job: 'Designer', company: 'Hut4', salary: '42,000 EUR', start_date: '2027-01-04', expires_on: '2026-11-20',
}

/** The template with sample values, for the editor's preview. */
export function previewTemplate(text: string): string {
  return text.replace(/\{(candidate|job|company|salary|start_date|expires_on)\}/g, (_, k: string) => SAMPLE[k] ?? '')
}

export function templateProblem(subject: string, body: string): string | null {
  if (!subject.trim()) return 'Give the email a subject.'
  if (subject.length > 200) return 'Keep the subject under 200 characters.'
  if (!body.trim()) return 'Write the email.'
  if (body.length > 8000) return 'Keep the email under 8,000 characters.'
  return null
}

export function reasonKey(label: string): string {
  return label
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .replace(/^(\d)/, 'r_$1')
    .slice(0, 40)
}
