import { supabase } from '@/lib/supabase'

/**
 * Candidate files (plan 018a): CVs and the like live in the PRIVATE
 * `candidate-files` bucket at {application_id}/{file_id}.{ext}, described by
 * an application_files row. Reads go through short-lived signed URLs — there
 * is never a public address for a candidate's document. The bucket enforces
 * type and size server-side; these checks fail fast in the form.
 */

export const FILE_BUCKET = 'candidate-files'
export const FILE_MAX_BYTES = 10 * 1024 * 1024
export const SIGNED_URL_SECONDS = 120

const EXTENSION_BY_TYPE: Record<string, string> = {
  'application/pdf': 'pdf',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'text/plain': 'txt',
  'image/png': 'png',
  'image/jpeg': 'jpg',
}

export const FILE_ACCEPT = Object.keys(EXTENSION_BY_TYPE).join(',')

export const FILE_KINDS = [
  { key: 'cv', label: 'CV / résumé' },
  { key: 'cover_letter', label: 'Cover letter' },
  { key: 'portfolio', label: 'Portfolio / work sample' },
  { key: 'other', label: 'Other' },
] as const

export type FileKind = (typeof FILE_KINDS)[number]['key']

export function validateApplicationFile(file: { type: string; size: number; name: string }): string | null {
  if (!EXTENSION_BY_TYPE[file.type]) return 'Attach a PDF, Word document, text file or image.'
  if (file.size > FILE_MAX_BYTES) return 'Files must be 10 MB or smaller.'
  return null
}

export function fileObjectPath(applicationId: string, fileId: string, mimeType: string): string {
  return `${applicationId}/${fileId}.${EXTENSION_BY_TYPE[mimeType] ?? 'bin'}`
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

/** Upload the object, then describe it; a failed row insert removes the orphan. */
export async function uploadApplicationFile(input: {
  applicationId: string
  // Passed for the insert type; the database derives the true company from the
  // application (trigger) and never trusts this value.
  companyId: string
  file: File
  kind: FileKind
  uploadedBy: string | null
}): Promise<void> {
  const fileId = crypto.randomUUID()
  const path = fileObjectPath(input.applicationId, fileId, input.file.type)
  const { error: uploadError } = await supabase.storage
    .from(FILE_BUCKET)
    .upload(path, input.file, { contentType: input.file.type })
  if (uploadError) throw new Error(uploadError.message)

  const { error: rowError } = await supabase.from('application_files').insert({
    id: fileId,
    application_id: input.applicationId,
    company_id: input.companyId,
    kind: input.kind,
    storage_path: path,
    original_name: input.file.name,
    mime_type: input.file.type,
    size_bytes: input.file.size,
    uploaded_by: input.uploadedBy,
  })
  if (rowError) {
    await supabase.storage.from(FILE_BUCKET).remove([path])
    throw new Error(rowError.message)
  }
}

/** A short-lived link for one download; nothing is cached or shareable. */
export async function signedFileUrl(storagePath: string): Promise<string> {
  const { data, error } = await supabase.storage
    .from(FILE_BUCKET)
    .createSignedUrl(storagePath, SIGNED_URL_SECONDS)
  if (error || !data) throw new Error(error?.message ?? 'Could not create a download link.')
  return data.signedUrl
}

/** Remove the row first (RLS decides), then the object it described. */
export async function removeApplicationFile(fileId: string, storagePath: string): Promise<void> {
  const { data, error } = await supabase.from('application_files').delete().eq('id', fileId).select('id')
  if (error) throw new Error(error.message)
  if (!data?.length) throw new Error('You do not have permission to remove this file.')
  const { error: removeError } = await supabase.storage.from(FILE_BUCKET).remove([storagePath])
  if (removeError) console.warn('Candidate file object not removed:', removeError.message)
}

// Words that name the document, not the person — dropped from a CV file name.
const NOISE = /\b(cv|resume|résumé|curriculum|vitae|final|latest|new|updated|copy|eng|en|mk|v\d+|\d{2,4})\b/gi

/**
 * A candidate name guessed from a CV file name ("Ana_Ilievska_CV.pdf" →
 * "Ana Ilievska"). A guess for the person to correct before saving, never
 * silently trusted: the bulk upload shows it in an editable field.
 */
export function candidateNameFromFile(fileName: string): string {
  const stem = fileName.replace(/\.[a-z0-9]+$/i, '')
  const cleaned = stem
    .replace(/\([^)]*\)/g, ' ')
    .replace(/[_\-.,]+/g, ' ')
    .replace(NOISE, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  if (!cleaned) return stem.trim()
  return cleaned
    .split(' ')
    .map((w) => (w === w.toUpperCase() && w.length > 1 ? w[0] + w.slice(1).toLowerCase() : w[0]?.toUpperCase() + w.slice(1)))
    .join(' ')
}
