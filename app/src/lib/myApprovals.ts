/** A row of `my_approvals()` (0104) and the one line that sums it up. */
export type ApprovalItem = {
  id: string
  subject_type: 'request' | 'offer'
  subject_id: string
  company: string
  position: number
  steps: number
  label: string
  title: string
  created_at: string
  as_delegate: boolean
  detail: {
    // request
    headcount?: number
    reason?: string | null
    requester?: string
    budget?: { min?: number | null; max?: number | null; currency?: string } | null
    // offer
    terms?: { salary?: number; currency?: string; start_date?: string } | null
    in_band?: boolean | null
    band_note?: string | null
    application_id?: string
  } | null
}

const money = new Intl.NumberFormat('en-GB')

function band(b: NonNullable<ApprovalItem['detail']>['budget']): string | null {
  if (!b || (b.min == null && b.max == null)) return null
  return `band ${b.min != null ? money.format(b.min) : '…'}–${b.max != null ? money.format(b.max) : '…'} ${b.currency ?? ''}`.trim()
}

export function approvalSummary(item: ApprovalItem): string {
  const d = item.detail ?? {}
  if (item.subject_type === 'request') {
    return [d.requester ? `requested by ${d.requester}` : null, d.headcount ? `headcount ${d.headcount}` : null, band(d.budget), d.reason || null]
      .filter(Boolean)
      .join(' · ')
  }
  const t = d.terms ?? {}
  return [
    t.salary != null ? `${money.format(t.salary)} ${t.currency ?? ''}`.trim() : null,
    t.start_date ? `starts ${t.start_date}` : null,
    d.band_note ?? null,
  ]
    .filter(Boolean)
    .join(' · ')
}
