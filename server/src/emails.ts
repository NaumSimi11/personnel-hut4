import { env } from './env.js'

/**
 * Account-lifecycle email: getting somebody their first password, or a
 * replacement. Wording ported from the Hut4 leave system. A mail failure must
 * never break the invite — the caller still holds the temp password and the
 * return value just says "deliver it yourself".
 */
export type AccessEmailInput = {
  name: string
  email: string
  tempPassword: string
  kind: 'invite' | 'reset'
}

function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (c) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string,
  )
}

export function buildAccessEmail(input: AccessEmailInput): {
  subject: string
  html: string
} {
  const appUrl = env('APP_BASE_URL')?.replace(/\/+$/, '')
  const intro =
    input.kind === 'invite'
      ? 'An account has been created for you in Personnel, the Hut4 HR workspace.'
      : 'Your Personnel password has been reset by an administrator.'
  return {
    subject:
      input.kind === 'invite' ? 'Your Personnel account' : 'Your new Personnel password',
    html: [
      `<p>Hi ${escapeHtml(input.name)},</p>`,
      `<p>${intro}</p>`,
      `<p>Sign in with this temporary password — you will be asked to choose your own on first sign-in:</p>`,
      `<p style="font-size:18px;font-family:monospace;background:#f4f6f0;padding:12px 16px;border-radius:8px">${escapeHtml(input.tempPassword)}</p>`,
      appUrl ? `<p><a href="${escapeHtml(appUrl)}/login">Open Personnel</a></p>` : '',
      `<p>The temporary password stops working the moment you replace it.</p>`,
    ].join('\n'),
  }
}

/** Send via Resend when configured; throw otherwise so the caller reports emailSent=false. */
export async function sendAccessEmail(input: AccessEmailInput): Promise<void> {
  const apiKey = env('RESEND_API_KEY')
  const from = env('EMAIL_FROM')
  if (!apiKey || !from) throw new Error('Email delivery is not configured (RESEND_API_KEY / EMAIL_FROM)')
  const message = buildAccessEmail(input)
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to: [input.email], subject: message.subject, html: message.html }),
  })
  if (!response.ok) throw new Error(`Resend responded ${response.status}`)
}
