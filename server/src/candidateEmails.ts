import { env } from './env.js'
import { serviceDb } from './supabaseAdmin.js'

/**
 * Emails to candidates (0102): the database queues them, this renders and
 * sends them. The wording is a default HR can change here until there is a
 * template editor (spec point 9.13). A candidate has no PeopleOS login, so the
 * mail carries no link into the app; replies go to the company's HR inbox.
 */
export type CandidateEmailKind = 'received' | 'rejected' | 'withdrawn' | 'offer' | 'offer_reminder'
export type CandidateEmailData = {
  candidate?: string
  job?: string
  company?: string
  token?: string
  salary?: string | number | null
  currency?: string | null
  start_date?: string | null
  expires_on?: string | null
}

const BATCH = 50
const MAX_ATTEMPTS = 5

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string)
}

/** The candidate's private offer page (0106); null without a base URL or token. */
export function offerLink(data: CandidateEmailData, appBaseUrl: string | null | undefined): string | null {
  const base = appBaseUrl?.replace(/\/+$/, '')
  return base && data.token && /^[0-9a-f]{64}$/.test(data.token) ? `${base}/offer/${data.token}` : null
}

export function renderCandidateEmail(kind: CandidateEmailKind, data: CandidateEmailData, appBaseUrl?: string | null): { subject: string; html: string } {
  const name = data.candidate?.trim() || 'candidate'
  const job = data.job?.trim() || 'the role'
  const companyName = data.company?.trim() || ''
  const company = companyName || 'our company'
  const salary = data.salary != null && data.salary !== '' ? `${Number(data.salary).toLocaleString('en-GB')} ${data.currency ?? ''}`.trim() : null
  const until = data.expires_on ? ` Please answer by ${data.expires_on}.` : ''
  const paragraphs: Record<CandidateEmailKind, { subject: string; body: string[] }> = {
    offer: {
      subject: `Your offer: ${job} at ${company}`,
      body: [
        `We are delighted to offer you the position of ${job} at ${company}.`,
        [salary ? `Salary: ${salary}.` : '', data.start_date ? `Start date: ${data.start_date}.` : ''].filter(Boolean).join(' '),
        `Please review the offer and accept or decline it through the link below.${until}`,
      ].filter(Boolean),
    },
    offer_reminder: {
      subject: `Reminder: your offer for ${job} expires soon`,
      body: [
        `This is a reminder that our offer for ${job} at ${company} is waiting for your answer.${until}`,
        'You can accept or decline it through the link below.',
      ],
    },
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
  const link = kind === 'offer' || kind === 'offer_reminder' ? offerLink(data, appBaseUrl) : null
  return {
    subject: message.subject,
    html: [
      `<p>Dear ${escapeHtml(name)},</p>`,
      ...message.body.map((p) => `<p>${escapeHtml(p)}</p>`),
      link ? `<p><a href="${escapeHtml(link)}">View and answer your offer</a></p>` : '',
      `<p>Kind regards,<br>${companyName ? `The ${escapeHtml(companyName)} team` : 'The hiring team'}</p>`,
    ]
      .filter(Boolean)
      .join('\n'),
  }
}

/**
 * HR's own wording (0109 email_templates): plain text with {candidate} {job}
 * {company} {salary} {start_date} {expires_on}; blank lines make paragraphs.
 * Offer emails always end with the private link.
 */
export type EmailTemplate = { subject: string; body: string }

export function fillPlaceholders(text: string, data: CandidateEmailData): string {
  const values: Record<string, string> = {
    candidate: data.candidate?.trim() || 'candidate',
    job: data.job?.trim() || 'the role',
    company: data.company?.trim() || 'our company',
    salary: data.salary != null && data.salary !== '' ? `${Number(data.salary).toLocaleString('en-GB')} ${data.currency ?? ''}`.trim() : '',
    start_date: data.start_date ?? '',
    expires_on: data.expires_on ?? '',
  }
  return text.replace(/\{(candidate|job|company|salary|start_date|expires_on)\}/g, (_, k: string) => values[k] ?? '')
}

export function renderFromTemplate(kind: CandidateEmailKind, tpl: EmailTemplate, data: CandidateEmailData, appBaseUrl?: string | null): { subject: string; html: string } {
  const link = kind === 'offer' || kind === 'offer_reminder' ? offerLink(data, appBaseUrl) : null
  const paragraphs = fillPlaceholders(tpl.body, data)
    .split(/\n{2,}/)
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => `<p>${escapeHtml(p).replace(/\n/g, '<br>')}</p>`)
  return {
    subject: fillPlaceholders(tpl.subject, data).replace(/[\r\n]+/g, ' ').trim(),
    html: [...paragraphs, link ? `<p><a href="${escapeHtml(link)}">View and answer your offer</a></p>` : ''].filter(Boolean).join('\n'),
  }
}

type Row = {
  id: string
  company_id: string
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
  const base = env('APP_BASE_URL')
  const result = { sent: 0, failed: 0, pending: 0 }
  const { data: rows, error } = await db
    .from('candidate_emails')
    .select('id, company_id, kind, email_to, reply_to, data, attempts')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
    .limit(BATCH)
  if (error) throw new Error(error.message)
  const list = (rows ?? []) as Row[]
  const templates = await loadTemplates(list.map((r) => r.company_id))
  for (const row of list) {
    if (!key || !from) {
      result.pending += 1
      continue
    }
    // An offer email without its link would be useless: it waits until APP_BASE_URL is set.
    if ((row.kind === 'offer' || row.kind === 'offer_reminder') && !offerLink(row.data ?? {}, base)) {
      result.pending += 1
      continue
    }
    const tpl = templates.get(`${row.company_id}:${row.kind}`) ?? templates.get(`*:${row.kind}`)
    const mail = tpl ? renderFromTemplate(row.kind, tpl, row.data ?? {}, base) : renderCandidateEmail(row.kind, row.data ?? {}, base)
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

/** Company templates keyed `company:kind`, holding-wide ones `*:kind`. A failed read falls back to the built-in wording. */
async function loadTemplates(companyIds: string[]): Promise<Map<string, EmailTemplate>> {
  const out = new Map<string, EmailTemplate>()
  if (!companyIds.length) return out
  const ids = [...new Set(companyIds)]
  const { data, error } = await serviceDb()
    .from('email_templates')
    .select('company_id, kind, subject, body')
    .or(`company_id.is.null,company_id.in.(${ids.join(',')})`)
  if (error) {
    console.warn('[candidate-emails] templates not loaded, using the built-in wording:', error.message)
    return out
  }
  for (const t of (data ?? []) as { company_id: string | null; kind: string; subject: string; body: string }[]) {
    out.set(`${t.company_id ?? '*'}:${t.kind}`, { subject: t.subject, body: t.body })
  }
  return out
}

/** The deadlines (0103): offer expiry and first response. Their alerts land in the notification queue. */
export async function runHiringClocks(): Promise<void> {
  const { error } = await serviceDb().rpc('run_hiring_clocks')
  if (error) console.error('[hiring-clocks] failed:', error.message)
}
