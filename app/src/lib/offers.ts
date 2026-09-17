import { z } from 'zod'

/**
 * Offers (plan 018b). Terms are explicit fields in offers.terms; status moves
 * only through advance_offer (migration 0014), which enforces the transition
 * table and that the approver is not the author. This file validates the
 * builder form and mirrors the transitions so the UI offers only what the
 * database would accept.
 */

export type OfferTerms = {
  salary: number
  currency: string
  pay_basis: string
  start_date: string
  employment_type: string
  notes?: string
}

export const offerTermsInput = z
  .object({
    salary: z.coerce.number().positive('Enter the salary amount.').max(100_000_000, 'That salary looks wrong.'),
    currency: z
      .string()
      .trim()
      .toUpperCase()
      .regex(/^[A-Z]{3}$/, 'Currency must be a three-letter code like EUR or MKD.'),
    payBasis: z.string().min(1, 'Choose how the salary is expressed.'),
    startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the start date.'),
    employmentType: z.string().min(1, 'Choose the employment type.'),
    notes: z.string().trim().max(1000, 'Keep the notes under 1000 characters.'),
  })
  .transform((input) => ({ ...input, salary: Math.round(input.salary * 100) / 100 }))

// The form holds strings (inputs); the schema coerces the salary.
export type OfferTermsForm = {
  salary: string
  currency: string
  payBasis: string
  startDate: string
  employmentType: string
  notes: string
}

export function termsToRow(input: z.infer<typeof offerTermsInput>): OfferTerms {
  return {
    salary: input.salary,
    currency: input.currency,
    pay_basis: input.payBasis,
    start_date: input.startDate,
    employment_type: input.employmentType,
    ...(input.notes && { notes: input.notes }),
  }
}

export function termsFromOffer(raw: unknown): OfferTermsForm {
  const record = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {}
  const str = (key: string) => (typeof record[key] === 'string' ? (record[key] as string) : '')
  return {
    salary: typeof record.salary === 'number' ? String(record.salary) : '',
    currency: str('currency') || 'EUR',
    payBasis: str('pay_basis') || 'annual',
    startDate: str('start_date'),
    employmentType: str('employment_type') || 'full_time',
    notes: str('notes'),
  }
}

export type OfferAction = { to: string; label: string }

export function offerActions(
  offer: { status: string; created_by: string | null },
  personId: string | null,
  can: (capability: string) => boolean,
): OfferAction[] {
  const review = can('candidates.review')
  const actions: OfferAction[] = []
  switch (offer.status) {
    case 'draft':
      if (review) actions.push({ to: 'in_approval', label: 'Submit for approval' })
      break
    case 'in_approval':
      // The holding's decision (September 2026): one person may carry an offer
      // the whole way, including approving one they drafted. The separation of
      // author and approver was dropped because a company of this size often
      // has only one person holding offer.approve. `approved_by` still records
      // who approved, so an offer approved by its own author is visible in the
      // record rather than prevented.
      if (can('offer.approve')) {
        actions.push({ to: 'approved', label: 'Approve' }, { to: 'draft', label: 'Send back' })
      }
      break
    case 'approved':
      if (review) actions.push({ to: 'extended', label: 'Mark as extended' })
      break
    case 'extended':
      if (review) {
        actions.push({ to: 'accepted', label: 'Candidate accepted' }, { to: 'declined', label: 'Candidate declined' })
      }
      break
    default:
      return actions
  }
  // Any non-terminal offer can be withdrawn by a reviewer — the author is
  // never stuck waiting on an approver (one open offer per application).
  if (review && ['draft', 'in_approval', 'approved', 'extended'].includes(offer.status)) {
    actions.push({ to: 'withdrawn', label: 'Withdraw offer' })
  }
  return actions
}

export function offerStatusLabel(status: string): string {
  return status.replace('_', ' ')
}

/**
 * The chain an offer walks, shown as a strip on the offer card.
 *
 * The five steps are not ceremony to be compressed: submitting, approving,
 * extending and hearing back are four different people-facts, and the approver
 * may not be the author. What made them *feel* like ceremony was that the card
 * named only the current status, so there was no way to see how far along the
 * offer was or what remained. Naming the whole chain fixes that without
 * weakening a single gate.
 */
export type OfferStageId = 'draft' | 'in_approval' | 'approved' | 'extended' | 'accepted'

export const OFFER_STAGES: readonly { id: OfferStageId; number: string; label: string }[] = [
  { id: 'draft', number: '01', label: 'Drafted' },
  { id: 'in_approval', number: '02', label: 'In approval' },
  { id: 'approved', number: '03', label: 'Approved' },
  { id: 'extended', number: '04', label: 'Extended' },
  { id: 'accepted', number: '05', label: 'Accepted' },
]

/** Where a live offer sits, or null for one that left the chain. */
export function offerStage(status: string): OfferStageId | null {
  const stage = OFFER_STAGES.find((s) => s.id === status)
  return stage ? stage.id : null
}
