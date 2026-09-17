import { z } from 'zod'
import { supabase } from '@/lib/supabase'

/**
 * Document requests and policies (plan 028). Requests move through
 * submit_requested_document / review_document_request; policies through
 * publish_policy / archive_policy / acknowledge_policy (migration 0021).
 * Policy files live in the PRIVATE `policies` bucket at
 * {company_id|holding}/{policy_id}/{file_id}.{ext} — one object per version,
 * readable through a visible row.
 */

// ----------------------------------------------------------- requests

export const requestInput = z.object({
  categoryKey: z.string().min(1, 'Choose what to request.'),
  dueDate: z.string().regex(/^(\d{4}-\d{2}-\d{2})?$/, 'Choose a date.'),
  note: z.string().trim().max(500, 'Keep the note under 500 characters.'),
})

export type RequestForm = z.input<typeof requestInput>

const REQUEST_STATUS: Record<string, string> = {
  pending: 'Waiting for the document',
  submitted: 'Submitted — awaiting review',
  accepted: 'Accepted',
  needs_correction: 'Needs a correction',
  cancelled: 'Cancelled',
}

export function requestStatusLabel(status: string): string {
  return REQUEST_STATUS[status] ?? status
}

export type DocumentRequestRow = {
  id: string
  company_id: string
  person_id: string
  category_key: string
  due_date: string | null
  reviewer_id: string | null
  status: string
  fulfilled_document_id: string | null
  note: string | null
  created_at: string
}

export const OPEN_REQUEST = new Set(['pending', 'needs_correction'])

export function friendlyRequestError(message: string): string {
  if (/row-level security|documents\.request/.test(message)) return 'You need documents.request in this company.'
  return message
}

// ------------------------------------------------------------- policies

export const POLICY_BUCKET = 'policies'
export const POLICY_MAX_BYTES = 20 * 1024 * 1024
export const SIGNED_URL_SECONDS = 120

const EXTENSION_BY_TYPE: Record<string, string> = {
  'application/pdf': 'pdf',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
}

export const POLICY_ACCEPT = Object.keys(EXTENSION_BY_TYPE).join(',')

export function validatePolicyFile(file: { type: string; size: number }): string | null {
  if (!EXTENSION_BY_TYPE[file.type]) return 'Attach the policy as a PDF or Word document.'
  if (file.size > POLICY_MAX_BYTES) return 'Policy files must be 20 MB or smaller.'
  return null
}

/** Each file gets its own object under the policy: versions never overwrite each other. */
export function policyObjectPath(companyId: string | null, policyId: string, mimeType: string, fileId: string = crypto.randomUUID()): string {
  return `${companyId ?? 'holding'}/${policyId}/${fileId}.${EXTENSION_BY_TYPE[mimeType] ?? 'bin'}`
}

export const policyInput = z.object({
  title: z.string().trim().min(2, 'Enter the policy title.').max(160),
  summary: z.string().trim().max(500, 'Keep the summary under 500 characters.'),
  body: z.string().trim().max(20000, 'Keep the text under 20,000 characters.').default(''),
})

export type PolicyRow = {
  id: string
  company_id: string | null
  title: string
  storage_path: string | null
  version: number
  status: string
  published_at: string | null
  published_by: string | null
  original_name: string | null
  mime_type: string | null
  summary: string | null
  body: string | null
  created_at: string
}

export type AcknowledgementLite = { policy_id: string; version: number }

/** Only an acknowledgement of the current version counts. */
export function acknowledgementState(
  policy: { id: string; version: number },
  acks: AcknowledgementLite[],
): 'acknowledged' | 'outdated' | 'pending' {
  const mine = acks.filter((a) => a.policy_id === policy.id)
  if (mine.some((a) => a.version === policy.version)) return 'acknowledged'
  return mine.length ? 'outdated' : 'pending'
}

/** Create the draft row first (RLS decides), then store the file and attach it. */
/** A draft with its text, its file, or both (plan 050: a policy need not be a PDF). */
export async function createPolicy(input: {
  companyId: string | null
  title: string
  summary: string
  body?: string
  file: File | null
}): Promise<PolicyRow> {
  const { data: created, error: rowError } = await supabase
    .from('policies')
    .insert({ company_id: input.companyId, title: input.title, summary: input.summary || null, body: input.body || null })
    .select('*')
    .maybeSingle()
  if (rowError || !created) throw new Error(friendlyPolicyError(rowError?.message ?? 'row-level security'))
  if (!input.file) return created as PolicyRow
  const path = policyObjectPath(input.companyId, created.id, input.file.type)
  const { error: uploadError } = await supabase.storage
    .from(POLICY_BUCKET)
    .upload(path, input.file, { contentType: input.file.type })
  if (uploadError) {
    await supabase.from('policies').delete().eq('id', created.id)
    throw new Error(friendlyPolicyError(uploadError.message))
  }
  const { data: attached, error: attachError } = await supabase
    .from('policies')
    .update({ storage_path: path, original_name: input.file.name.slice(0, 200), mime_type: input.file.type })
    .eq('id', created.id)
    .select('*')
    .maybeSingle()
  if (attachError || !attached) throw new Error(friendlyPolicyError(attachError?.message ?? 'row-level security'))
  return attached as PolicyRow
}

/** Store a file for the policy; the caller decides whether it becomes the draft's file or a new version. */
async function storePolicyFile(policy: PolicyRow, file: File): Promise<string> {
  const path = policyObjectPath(policy.company_id, policy.id, file.type)
  const { error } = await supabase.storage.from(POLICY_BUCKET).upload(path, file, { contentType: file.type })
  if (error) throw new Error(friendlyPolicyError(error.message))
  return path
}

/** Replace a draft's file (a published file is frozen with its version). */
export async function replaceDraftFile(policy: PolicyRow, file: File): Promise<void> {
  const path = await storePolicyFile(policy, file)
  const { data, error } = await supabase
    .from('policies')
    .update({ storage_path: path, original_name: file.name.slice(0, 200), mime_type: file.type })
    .eq('id', policy.id)
    .select('id')
    .maybeSingle()
  if (error || !data) {
    await supabase.storage.from(POLICY_BUCKET).remove([path])
    throw new Error(friendlyPolicyError(error?.message ?? 'row-level security'))
  }
  if (policy.storage_path) await supabase.storage.from(POLICY_BUCKET).remove([policy.storage_path])
}

/** Publish: a draft as it is, or a published policy as a new version with the new file or the new text. */
export async function publishPolicy(policy: PolicyRow, file: File | null, body?: string): Promise<void> {
  const path = file ? await storePolicyFile(policy, file) : null
  const { error } = await supabase.rpc('publish_policy', {
    p_policy_id: policy.id,
    p_storage_path: path ?? undefined,
    p_original_name: file ? file.name.slice(0, 200) : undefined,
    p_mime_type: file?.type,
    p_body: body?.trim() || undefined,
  })
  if (error) {
    if (path) await supabase.storage.from(POLICY_BUCKET).remove([path])
    throw new Error(friendlyPolicyError(error.message))
  }
}

export async function signedPolicyUrl(storagePath: string): Promise<string> {
  const { data, error } = await supabase.storage.from(POLICY_BUCKET).createSignedUrl(storagePath, SIGNED_URL_SECONDS)
  if (error || !data) throw new Error(error?.message ?? 'Could not create a link to the policy.')
  return data.signedUrl
}

export function friendlyPolicyError(message: string): string {
  if (/row-level security|policies\.publish/.test(message)) {
    return 'You need policies.publish in this company (holding-wide policies: platform admins).'
  }
  return message
}
