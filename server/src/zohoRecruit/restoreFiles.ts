import path from 'node:path'
import type { CsvRow } from './csv.js'

/**
 * Re-attach the candidate files of the 2026-11-05 backup to the candidates the
 * Zoho import re-created, matched by Zoho Candidate ID (provider_ref). Pure:
 * the script does the I/O.
 */

export type RestoreUpload = { fileId: string; from: string; to: string; row: Record<string, unknown> }
export type RestoreSkip = { fileId: string; reason: string }
export type RestorePlan = { uploads: RestoreUpload[]; skipped: RestoreSkip[] }

const orNull = (v: string | undefined): string | null => (v === undefined || v === '' ? null : v)

export function planRestore(oldCandidates: CsvRow[], oldFiles: CsvRow[], newIdByRef: ReadonlyMap<string, string>): RestorePlan {
  const refByOldId = new Map(oldCandidates.map((c) => [c.id, c.provider_ref ?? '']))
  const uploads: RestoreUpload[] = []
  const skipped: RestoreSkip[] = []
  for (const f of oldFiles) {
    const ref = refByOldId.get(f.candidate_id)
    if (ref === undefined) {
      skipped.push({ fileId: f.id, reason: 'candidate not in backup' })
      continue
    }
    if (ref === '') {
      skipped.push({ fileId: f.id, reason: 'manual candidate' })
      continue
    }
    const newId = newIdByRef.get(ref)
    if (!newId) {
      skipped.push({ fileId: f.id, reason: 'not re-imported' })
      continue
    }
    const to = `candidate/${newId}/${f.id}${path.extname(f.storage_path)}`
    uploads.push({
      fileId: f.id,
      from: f.storage_path,
      to,
      row: {
        id: f.id,
        candidate_id: newId,
        kind: f.kind,
        storage_path: to,
        original_name: f.original_name,
        mime_type: f.mime_type,
        size_bytes: Number(f.size_bytes),
        uploaded_by: orNull(f.uploaded_by),
        extracted_text: orNull(f.extracted_text),
        provider: orNull(f.provider),
        provider_ref: orNull(f.provider_ref),
        created_at: f.created_at,
      },
    })
  }
  return { uploads, skipped }
}
