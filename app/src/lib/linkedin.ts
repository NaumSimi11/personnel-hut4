/**
 * A candidate's LinkedIn address as a link that is safe to put in an href:
 * http(s) only, a bare "www.linkedin.com/in/…" given its https://, anything
 * else (a `javascript:` URL, a note someone typed in the field) null.
 * Imported data is never trusted as a link by itself.
 */
const SCHEME = /^[a-z][a-z0-9+.-]*:/i

export function linkedinHref(raw: string | null | undefined): string | null {
  const value = (raw ?? '').trim()
  if (!value || /\s/.test(value)) return null
  const withScheme = SCHEME.test(value) ? value : `https://${value.replace(/^\/+/, '')}`
  try {
    const url = new URL(withScheme)
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null
    if (!url.hostname.includes('.')) return null
    return url.href
  } catch {
    return null
  }
}
