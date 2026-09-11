import { z } from 'zod'
import { supabase } from '@/lib/supabase'

/**
 * Employee and company documents (plan 026). Files live in the PRIVATE
 * `employee-documents` bucket at {company_id}/{person_id|company}/{id}.{ext},
 * described by a `documents` row whose RLS (0006) decides who sees what;
 * storage reads are gated by that same row. The database sets the uploader,
 * checks scope and categories, and handles versioning (0019).
 */

export const DOCUMENT_BUCKET = 'employee-documents'
export const DOCUMENT_MAX_BYTES = 20 * 1024 * 1024
export const SIGNED_URL_SECONDS = 120

const EXTENSION_BY_TYPE: Record<string, string> = {
  'application/pdf': 'pdf',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'image/png': 'png',
  'image/jpeg': 'jpg',
}

export const DOCUMENT_ACCEPT = Object.keys(EXTENSION_BY_TYPE).join(',')

export function validateDocumentFile(file: { type: string; size: number; name: string }): string | null {
  if (!EXTENSION_BY_TYPE[file.type]) return 'Attach a PDF, Word document or image (PNG, JPEG).'
  if (file.size > DOCUMENT_MAX_BYTES) return 'Documents must be 20 MB or smaller.'
  return null
}

export function documentObjectPath(companyId: string, personId: string | null, documentId: string, mimeType: string): string {
  return `${companyId}/${personId ?? 'company'}/${documentId}.${EXTENSION_BY_TYPE[mimeType] ?? 'bin'}`
}

export const VISIBILITIES = ['hr_only', 'person_and_hr', 'company_public'] as const
export type Visibility = (typeof VISIBILITIES)[number]

const VISIBILITY_LABELS: Record<Visibility, string> = {
  hr_only: 'HR only',
  person_and_hr: 'The person and HR',
  company_public: 'Everyone in the company',
}

export function visibilityLabel(key: string): string {
  return VISIBILITY_LABELS[key as Visibility] ?? key
}

export function visibilityOptions(scope: 'person' | 'company'): { key: Visibility; label: string }[] {
  const keys: Visibility[] = scope === 'person' ? ['person_and_hr', 'hr_only'] : ['company_public', 'hr_only']
  return keys.map((key) => ({ key, label: VISIBILITY_LABELS[key] }))
}

export const documentInput = z.object({
  title: z.string().trim().min(2, 'Enter the document title.').max(160),
  categoryKey: z.string().min(1, 'Choose the document category.'),
  visibility: z.enum(VISIBILITIES),
  note: z.string().trim().max(500, 'Keep the note under 500 characters.'),
})

export type DocumentForm = z.input<typeof documentInput>

export type DocumentRow = {
  id: string
  company_id: string
  person_id: string | null
  category_key: string
  title: string
  storage_path: string
  version: number
  supersedes_id: string | null
  visibility: string
  uploaded_by: string | null
  archived_at: string | null
  created_at: string
  original_name: string | null
  mime_type: string | null
  size_bytes: number | null
  note: string | null
}

/** Upload the object, then describe it; a failed row insert removes the orphan. */
export async function uploadDocument(input: {
  companyId: string
  personId: string | null
  file: File
  form: z.output<typeof documentInput>
  supersedesId?: string | null
}): Promise<DocumentRow> {
  const id = crypto.randomUUID()
  const path = documentObjectPath(input.companyId, input.personId, id, input.file.type)
  const { error: uploadError } = await supabase.storage
    .from(DOCUMENT_BUCKET)
    .upload(path, input.file, { contentType: input.file.type })
  if (uploadError) throw new Error(friendlyDocumentError(uploadError.message))

  const { data, error: rowError } = await supabase
    .from('documents')
    .insert({
      id,
      company_id: input.companyId,
      person_id: input.personId,
      category_key: input.form.categoryKey,
      title: input.form.title,
      visibility: input.form.visibility,
      note: input.form.note || null,
      storage_path: path,
      original_name: input.file.name.slice(0, 200),
      mime_type: input.file.type,
      size_bytes: input.file.size,
      supersedes_id: input.supersedesId ?? null,
    })
    .select('*')
    .maybeSingle()
  if (rowError || !data) {
    await supabase.storage.from(DOCUMENT_BUCKET).remove([path])
    throw new Error(friendlyDocumentError(rowError?.message ?? 'row-level security'))
  }
  return data as DocumentRow
}

/** A short-lived link for one download; nothing is cached or shareable. */
export async function signedDocumentUrl(storagePath: string): Promise<string> {
  const { data, error } = await supabase.storage.from(DOCUMENT_BUCKET).createSignedUrl(storagePath, SIGNED_URL_SECONDS)
  if (error || !data) throw new Error(error?.message ?? 'Could not create a download link.')
  return data.signedUrl
}

/** Archive keeps the row and the file; nothing about a document is ever deleted. */
export async function archiveDocument(id: string): Promise<void> {
  const { data, error } = await supabase
    .from('documents')
    .update({ archived_at: new Date().toISOString() })
    .eq('id', id)
    .select('id')
    .maybeSingle()
  if (error) throw new Error(friendlyDocumentError(error.message))
  if (!data) throw new Error('You need documents.upload in this company to archive documents.')
}

export function friendlyDocumentError(message: string): string {
  if (/row-level security|documents\.upload/.test(message)) {
    return 'You need documents.upload in this company to add documents.'
  }
  if (/mime type|not supported/i.test(message)) return 'Attach a PDF, Word document or image (PNG, JPEG).'
  if (/exceeded the maximum allowed size|too large/i.test(message)) return 'Documents must be 20 MB or smaller.'
  return message
}
