/**
 * The candidate's offer page endpoints (0106). Anonymous, like the careers
 * pages: plain fetches to the server, the token in the path is the key.
 */
export type CandidateOffer = {
  status: 'extended' | 'accepted' | 'declined'
  candidate: string
  job: string
  company: string
  salary: string | null
  currency: string | null
  pay_basis: string | null
  employment_type: string | null
  start_date: string | null
  bonus?: string | null
  benefits?: string | null
  conditions?: string | null
  expires_on: string | null
  expired: boolean
  answered_at: string | null
}

async function readJson<T>(response: Response): Promise<T> {
  const body = (await response.json().catch(() => ({}))) as T & { error?: string }
  if (!response.ok) throw new Error(body.error ?? 'Something went wrong. Please try again.')
  return body
}

export const OFFER_TOKEN = /^[0-9a-f]{64}$/

export async function fetchOffer(token: string): Promise<CandidateOffer> {
  return readJson(await fetch(`/api/offer/${encodeURIComponent(token)}`))
}

export async function answerOffer(token: string, answer: 'accepted' | 'declined', reason?: string): Promise<{ status: string }> {
  return readJson(
    await fetch(`/api/offer/${encodeURIComponent(token)}/answer`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ answer, reason: reason?.trim() || undefined }),
    }),
  )
}

/** What the page can do with the offer as it stands. */
export function offerState(o: CandidateOffer): 'answer' | 'expired' | 'accepted' | 'declined' {
  if (o.status === 'accepted') return 'accepted'
  if (o.status === 'declined') return 'declined'
  return o.expired ? 'expired' : 'answer'
}

export function salaryLine(o: CandidateOffer): string | null {
  if (!o.salary) return null
  const amount = Number(o.salary)
  const text = Number.isFinite(amount) ? amount.toLocaleString('en-GB') : o.salary
  return [text, o.currency, o.pay_basis ? `(${o.pay_basis.toLowerCase()})` : null].filter(Boolean).join(' ')
}
