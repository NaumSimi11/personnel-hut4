import { z } from 'zod'

/**
 * Equipment & IT (plan 029): the asset register form, the assignment and
 * IT-request action mirrors of migration 0022's functions, and labels. The
 * database owns every rule (status sync, one open assignment, employment
 * in the company, capability gates); these only shape what is offered.
 */

export const assetInput = z.object({
  assetTag: z.string().trim().min(2, 'Enter the asset tag.').max(60),
  typeKey: z.string().min(1, 'Choose the asset type.'),
  model: z.string().trim().max(120),
  serialNumber: z.string().trim().max(120),
  locationId: z.string(),
  note: z.string().trim().max(500, 'Keep the note under 500 characters.'),
})

export type AssetForm = z.input<typeof assetInput>

const ASSET_STATUS: Record<string, string> = {
  available: 'Available',
  reserved: 'Reserved',
  assigned: 'Assigned',
  damaged: 'Damaged',
  lost: 'Lost',
  retired: 'Retired',
}

export function assetStatusLabel(status: string): string {
  return ASSET_STATUS[status] ?? status
}

export const RETURN_STATUSES = [
  { key: 'available', label: 'Back in stock' },
  { key: 'damaged', label: 'Damaged' },
  { key: 'lost', label: 'Lost' },
  { key: 'retired', label: 'Retired' },
] as const

export type AssignmentAction = { key: 'reserve' | 'issue' | 'cancel' | 'return'; label: string }

/** What the viewer may do with an asset given its open assignment (if any). */
export function assignmentActions(
  asset: { status: string },
  open: { issued_at: string | null; returned_at: string | null } | null,
  can: (cap: string) => boolean,
): AssignmentAction[] {
  const assign = can('it.assign')
  const handle = assign || can('it.complete')
  if (asset.status === 'available') return assign ? [{ key: 'reserve', label: 'Reserve' }] : []
  if (!open || open.returned_at !== null) return []
  if (open.issued_at === null) {
    const out: AssignmentAction[] = handle ? [{ key: 'issue', label: 'Issue' }] : []
    if (assign) out.push({ key: 'cancel', label: 'Cancel reservation' })
    return out
  }
  return handle ? [{ key: 'return', label: 'Return' }] : []
}

// ------------------------------------------------------------ IT requests

export const itRequestInput = z.object({
  personId: z.string().min(1, 'Choose who it is for.'),
  title: z.string().trim().min(2, 'Enter what is needed.').max(160),
  systems: z.string().trim().max(500),
  dueDate: z.string().regex(/^(\d{4}-\d{2}-\d{2})?$/, 'Choose a date.'),
})

export type ItRequestForm = z.input<typeof itRequestInput>

export function parseSystems(raw: string): string[] {
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
}

const REQUEST_STATUS: Record<string, string> = {
  open: 'Open',
  in_progress: 'In progress',
  blocked: 'Blocked',
  done: 'Done',
  cancelled: 'Cancelled',
}

export function itRequestStatusLabel(status: string): string {
  return REQUEST_STATUS[status] ?? status
}

export type ItRequestAction = { to: 'open' | 'in_progress' | 'blocked' | 'done' | 'cancelled'; label: string }

/** Mirrors advance_it_request: it.assign works a request, it.complete may close it. */
export function itRequestActions(status: string, can: (cap: string) => boolean): ItRequestAction[] {
  if (status === 'done' || status === 'cancelled') return []
  const assign = can('it.assign')
  const complete = assign || can('it.complete')
  const out: ItRequestAction[] = []
  if (assign && status !== 'in_progress') out.push({ to: 'in_progress', label: status === 'blocked' ? 'Unblock' : 'Start' })
  if (assign && status !== 'blocked') out.push({ to: 'blocked', label: 'Block' })
  if (complete) out.push({ to: 'done', label: 'Done' })
  if (assign) out.push({ to: 'cancelled', label: 'Cancel' })
  return out
}
