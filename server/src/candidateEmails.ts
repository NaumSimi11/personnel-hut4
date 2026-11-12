import { env } from './env.js'
import { serviceDb } from './supabaseAdmin.js'

/**
 * Emails to candidates (0102): the database queues them, this renders and
 * sends them. The wording is a default HR can change here until there is a
 * template editor (spec point 9.13). A candidate has no PeopleOS login, so the
 * mail carries no link into the app; replies go to the company's HR inbox.
 */
export type CandidateEmailKind = 'received' | 'rejected' | 'withdrawn'
export type CandidateEmailData = { candidate?: string; job?: string; company?: string }

const BATCH = 50
const MAX_ATTEMPTS = 5

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string)
}

export function renderCandidateEmail(kind: CandidateEmailKind, data: CandidateEmailData): { subject: string; html: string } {
  const name = data.candidate?.trim() || 'candidate'
  const job = data.job?.trim() || 'the role'
  const companyName = data.company?.trim() || ''
  const company = companyName || 'our company'
  const paragraphs: Record<CandidateEmailKind, { subject: string; body: string[] }> = {
    received: {
      subject: `We received your application: ${job}`,
      body: [
        `Thank you for applying for ${job} at ${company}.`,
        'We have received your application and will review it carefully. If your profile matches what we are looking for, we will contact you about the next steps.',
      ],
    },
    rejected: {
      subject: `Your application: ${job} at ${company}`,
      body: [
        `Thank you for your interest in ${job} at ${company} and for the time you gave to the process.`,
        'After careful consideration, we have decided not to move forward with your application for this role.',
        'We will keep your details on file and may contact you about future openings. We wish you every success.',
      ],
    },
    withdrawn: {
      subject: `Your application has been withdrawn: ${job}`,
      body: [
        `This confirms that your application for ${job} at ${company} has been withdrawn, as you asked.`,
        'Thank you for considering us. You are welcome to apply again for any future opening.',
      ],
    },
  }
  const message = paragraphs[kind]
  return {
    subject: message.subject,
    html: [
      `<p>Dear ${escapeHtml(name)},</p>`,
      ...message.body.map((p) => `<p>${escapeHtml(p)}</p>`),
      `<p>Kind regards,<br>${companyName ? `The ${escapeHtml(companyName)} team` : 'The hiring team'}</p>`,
    ].join('\n'),
  }
}

type Row = {
  id: string
  kind: CandidateEmailKind
  email_to: string
  reply_to: string | null
  data: CandidateEmailData
  attempts: number
}

/** Send what is queued; each row records sent, failed (after five tries) or stays pending. */
export async function deliverCandidateEmails(): Promise<{ sent: number; failed: number; pending: number }> {
  const db = serviceDb()
  const key = env('RESEND_API_KEY')
  const from = env('EMAIL_FROM')
  const result = { sent: 0, failed: 0, pending: 0 }
  const { data: rows, error } = await db
    .from('candidate_emails')
    .select('id, kind, email_to, reply_to, data, attempts')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
    .limit(BATCH)
  if (error) throw new Error(error.message)
  for (const row of (rows ?? []) as Row[]) {
    if (!key || !from) {
      result.pending += 1
      continue
    }
    const mail = renderCandidateEmail(row.kind, row.data ?? {})
    try {
      const response = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Idempotency-Key': `candidate-email-${row.id}` },
        body: JSON.stringify({
          from,
          to: [row.email_to],
          ...(row.reply_to ? { reply_to: row.reply_to } : {}),
          subject: mail.subject,
          html: mail.html,
        }),
        signal: AbortSignal.timeout(10_000),
      })
      if (!response.ok) throw new Error(`Resend responded ${response.status}`)
      await db.from('candidate_emails').update({ status: 'sent', sent_at: new Date().toISOString(), attempts: row.attempts + 1, error: null }).eq('id', row.id)
      result.sent += 1
    } catch (e) {
      const attempts = row.attempts + 1
      const message = e instanceof Error ? e.message : String(e)
      console.warn(`[candidate-emails] ${row.kind} ${row.id} not delivered (attempt ${attempts}):`, message)
      await db
        .from('candidate_emails')
        .update({ status: attempts >= MAX_ATTEMPTS ? 'failed' : 'pending', attempts, error: message })
        .eq('id', row.id)
      if (attempts >= MAX_ATTEMPTS) result.failed += 1
      else result.pending += 1
    }
  }
  return result
}

/** The deadlines (0103): offer expiry and first response. Their alerts land in the notification queue. */
export async function runHiringClocks(): Promise<void> {
  const { error } = await serviceDb().rpc('run_hiring_clocks')
  if (error) console.error('[hiring-clocks] failed:', error.message)
}
