import { supabase } from '@/lib/supabase'
import { FILE_BUCKET, extensionFor } from '@/lib/applicationFiles'

/**
 * Files on the candidate (plan 052): the CV follows the person to every job.
 * Objects live in the same PRIVATE `candidate-files` bucket as the
 * application-keyed files, at candidate/{candidate_id}/{file_id}.{ext} —
 * the shape app.candidate_object_candidate resolves — described by a
 * candidate_files row. Reads go through the short-lived signed URLs of
 * lib/applicationFiles.ts (signedFileUrl); the storage and row policies
 * (can_view_candidate / can_edit_candidate) decide, never this file.
 */

export const CANDIDATE_FILE_KINDS = [
  { key: 'cv', label: 'CV' },
  { key: 'cover_letter', label: 'Cover letter' },
  { key: 'portfolio', label: 'Portfolio' },
  { key: 'profile', label: 'Profile capture (text)' },
  { key: 'other', label: 'Other' },
] as const

export type CandidateFileKind = (typeof CANDIDATE_FILE_KINDS)[number]['key']

export type CandidateFileRow = {
  id: string
  kind: CandidateFileKind
  storage_path: string
  original_name: string
  mime_type: string
  size_bytes: number
  created_at: string
  uploader: { full_name: string } | null
}

export function candidateFileObjectPath(candidateId: string, fileId: string, mimeType: string): string {
  return `candidate/${candidateId}/${fileId}.${extensionFor(mimeType)}`
}

/** The candidate's files, oldest first, with who attached each one. */
export async function listCandidateFiles(candidateId: string): Promise<CandidateFileRow[]> {
  const { data, error } = await supabase
    .from('candidate_files')
    .select(
      `id, kind, storage_path, original_name, mime_type, size_bytes, created_at,
       uploader:people!candidate_files_uploaded_by_fkey(full_name)`,
    )
    .eq('candidate_id', candidateId)
    .order('created_at')
  if (error) throw new Error(error.message)
  return (data ?? []) as CandidateFileRow[]
}

/**
 * Upload the object, then describe it; a failed row insert removes the
 * orphan. The row id is generated first so the object path carries it.
 */
export async function uploadCandidateFile(input: {
  candidateId: string
  file: File
  kind: CandidateFileKind
  uploadedBy: string | null
}): Promise<void> {
  const fileId = crypto.randomUUID()
  const path = candidateFileObjectPath(input.candidateId, fileId, input.file.type)
  const { error: uploadError } = await supabase.storage
    .from(FILE_BUCKET)
    .upload(path, input.file, { contentType: input.file.type })
  if (uploadError) throw new Error(uploadError.message)

  const { error: rowError } = await supabase.from('candidate_files').insert({
    id: fileId,
    candidate_id: input.candidateId,
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

/** Remove the row first (RLS decides), then the object it described. */
export async function removeCandidateFile(fileId: string, storagePath: string): Promise<void> {
  const { data, error } = await supabase.from('candidate_files').delete().eq('id', fileId).select('id')
  if (error) throw new Error(error.message)
  if (!data?.length) throw new Error('You do not have permission to remove this file.')
  const { error: removeError } = await supabase.storage.from(FILE_BUCKET).remove([storagePath])
  if (removeError) console.warn('Candidate file object not removed:', removeError.message)
}
