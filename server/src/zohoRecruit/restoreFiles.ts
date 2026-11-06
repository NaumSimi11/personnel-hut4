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

/**
 * The Zoho Candidate ID (ZR_…_CAND) of a backup candidate. The old import
 * keyed candidates by Zoho's internal id (provider_ref "Zrecruit_…") and kept
 * the display id in custom.zoho.display_id; the new import keys by the
 * display id. '' for a manual candidate (no provider_ref).
 */
export function zohoCandidateId(c: CsvRow): string {
  if ((c.provider_ref ?? '') === '') return ''
  try {
    const displayId = (JSON.parse(c.custom || '{}') as { zoho?: { display_id?: unknown } }).zoho?.display_id
    return typeof displayId === 'string' && displayId !== '' ? displayId : c.provider_ref
  } catch {
    return c.provider_ref
  }
}

export function planRestore(oldCandidates: CsvRow[], oldFiles: CsvRow[], newIdByRef: ReadonlyMap<string, string>): RestorePlan {
  const refByOldId = new Map(oldCandidates.map((c) => [c.id, zohoCandidateId(c)]))
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
