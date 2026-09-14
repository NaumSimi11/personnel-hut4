/**
 * The mail for one notification row: the title is the subject, the body a
 * paragraph, the link a button into the app. Plain on purpose — the row
 * already says everything the person needs.
 */
export type NotificationLike = { title: string; body: string | null; link: string | null; kind: string }

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string)
}

export function renderNotificationEmail(n: NotificationLike, appBaseUrl: string | null | undefined): { subject: string; html: string } {
  const base = appBaseUrl?.replace(/\/+$/, '')
  const href = base && n.link ? `${base}${n.link.startsWith('/') ? '' : '/'}${n.link}` : null
  return {
    subject: n.title,
    html: [
      `<p><strong>${escapeHtml(n.title)}</strong></p>`,
      n.body ? `<p>${escapeHtml(n.body)}</p>` : '',
      href ? `<p><a href="${escapeHtml(href)}">Open in Personnel</a></p>` : '',
      `<p style="color:#6b7a72;font-size:12px">You receive this because it concerns you in Personnel.</p>`,
    ]
      .filter(Boolean)
      .join('\n'),
  }
}
