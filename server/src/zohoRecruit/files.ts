import fs from 'node:fs'
import path from 'node:path'
import type { ZohoExport } from './csv.js'
import { longDate, parseUsDateTime } from './dates.js'

/**
 * Which Zoho attachments become candidate files (plan 052 §3.1 "Files", D6)
 * and the manifest the files script uploads from. Sizes come from disk (the
 * CSV sizes are wrong for 797 rows), names match NFC on both sides.
 */

export const FILE_MAX_BYTES = 10 * 1024 * 1024
export const TEXT_MAX_CHARS = 100 * 1024

export type ParentKind = 'candidate' | 'job' | 'interview' | 'note' | 'unknown'
export type AttachmentParent = { kind: ParentKind; candidateZohoId: string | null }
export type AttachmentRow = { attachmentId: string; fileName: string; category: string; parent: AttachmentParent }
export type DiskStat = { exists: boolean; size_bytes: number | null }
export type FileKind = 'cv' | 'cover_letter' | 'profile' | 'other'
export type Classification =
  | { candidateZohoId: string; kind: FileKind; textOnly: boolean; category?: 'Offer' }
  | { candidateZohoId: string | null; kind: 'skip'; reason: string }

export type ManifestRow = {
  attachment_id: string
  candidate_zoho_id: string
  kind: FileKind
  path: string
  original_name: string
  mime: string
  size_bytes: number
  created_at: string | null
  text_only: boolean
  owner_email: string | null
  category?: 'Offer'
}

const MIME: Readonly<Record<string, string>> = {
  '.pdf': 'application/pdf',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.html': 'text/html',
  '.htm': 'text/html',
}
const STORED_EXTS = new Set(['.pdf', '.doc', '.docx', '.jpg', '.jpeg', '.png'])
const HTML_EXTS = new Set(['.html', '.htm'])

/** The CSV `Size`: a number, once with a " bytes" suffix. */
export function parseCsvSize(value: string): number | null {
  const m = /^(\d+)(?: bytes)?$/.exec(value.trim())
  return m ? Number(m[1]) : null
}

/** The name after the 17-digit prefix, NFC, at most 200 characters. */
export function originalNameOf(fileName: string): string {
  const name = fileName.normalize('NFC').replace(/^\d{17}_/, '').trim()
  return (name === '' ? 'file' : name).slice(0, 200)
}

export function mimeFor(fileName: string): string | null {
  return MIME[path.extname(fileName).toLowerCase()] ?? null
}

function saysCv(fileName: string): boolean {
  return /\bcv\b|resume|résumé/i.test(originalNameOf(fileName))
}

export function classifyAttachment(row: AttachmentRow, disk: DiskStat): Classification {
  const skip = (reason: string): Classification => ({ candidateZohoId: row.parent.candidateZohoId, kind: 'skip', reason })
  const ext = path.extname(row.fileName).toLowerCase()
  if (!disk.exists) return skip('not on disk')
  if (row.category === 'Zrecruit_ICS') return skip('calendar invite')
  if (row.category === 'Zrecruit_Job Summary') return skip('job summary')
  if (row.parent.kind === 'job') return skip('attached to a job')
  if (row.parent.kind === 'interview') return skip('attached to an interview')
  if (!STORED_EXTS.has(ext) && !HTML_EXTS.has(ext)) return skip(`unsupported type ${ext || '(none)'}`)
  if ((disk.size_bytes ?? 0) > FILE_MAX_BYTES) return skip('over 10 MB')
  const candidateZohoId = row.parent.candidateZohoId
  if (!candidateZohoId) return skip('parent not a candidate')
  const textOnly = HTML_EXTS.has(ext)
  const stored = (kind: FileKind, category?: 'Offer'): Classification =>
    category ? { candidateZohoId, kind, textOnly, category } : { candidateZohoId, kind, textOnly }
  switch (row.category) {
    case 'Zrecruit_Resume':
      return textOnly ? stored('profile') : stored('cv')
    case 'Zrecruit_Cover Letter':
      return stored('cover_letter')
    case 'Zrecruit_Others':
      return stored('other')
    case 'Zrecruit_Offer':
      return stored('other', 'Offer')
    case '':
      if (row.parent.kind !== 'note') return skip('no category')
      return stored(saysCv(row.fileName) ? 'cv' : 'other')
    default:
      return skip(`unknown category ${row.category}`)
  }
}

const ENTITIES: Readonly<Record<string, string>> = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', copy: '©', reg: '®', trade: '™',
  hellip: '…', mdash: '—', ndash: '–', lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”', bull: '•', middot: '·',
}

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, body: string) => {
    if (body[0] === '#') {
      const code = body[1] === 'x' || body[1] === 'X' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10)
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole
    }
    return ENTITIES[body.toLowerCase()] ?? whole
  })
}

/** Tags and entities stripped, whitespace collapsed, capped at 100 kB. */
export function htmlToText(html: string): string {
  const text = html
    .replace(/<(script|style|noscript|template)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<\s*(br|hr)\b[^>]*>/gi, '\n')
    .replace(/<\/\s*(p|div|li|tr|h[1-6]|title|section|article|header|footer|blockquote|pre|table|ul|ol|dd|dt)\s*>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
  return decodeEntities(text)
    .replace(/\u00a0/g, ' ')
    .replace(/[ \t\f\v\r]+/g, ' ')
    .replace(/ ?\n ?/g, '\n')
    .replace(/\n{2,}/g, '\n')
    .trim()
    .slice(0, TEXT_MAX_CHARS)
}

/** The files on disk, keyed by NFC name. */
function diskIndex(dir: string): Map<string, { name: string; size: number }> {
  const index = new Map<string, { name: string; size: number }>()
  for (const name of fs.readdirSync(dir)) {
    const stat = fs.statSync(path.join(dir, name))
    if (stat.isFile()) index.set(name.normalize('NFC'), { name, size: stat.size })
  }
  return index
}

type ParentIndex = { candidates: Set<string>; jobs: Set<string>; interviews: Set<string>; noteCandidate: Map<string, string | null> }

function parentIndex(exp: ZohoExport): ParentIndex {
  const candidates = new Set(exp.candidates.map((r) => r['Candidate Id']))
  return {
    candidates,
    jobs: new Set(exp.jobs.map((r) => r['Job Opening Id'])),
    interviews: new Set(exp.interviews.map((r) => r['Interview Id'])),
    noteCandidate: new Map(exp.notes.map((r) => [r['Note Id'], candidates.has(r['Parent ID']) ? r['Parent ID'] : null])),
  }
}

function resolveParent(parentId: string, index: ParentIndex): AttachmentParent {
  if (index.candidates.has(parentId)) return { kind: 'candidate', candidateZohoId: parentId }
  if (index.jobs.has(parentId)) return { kind: 'job', candidateZohoId: null }
  if (index.interviews.has(parentId)) return { kind: 'interview', candidateZohoId: null }
  if (index.noteCandidate.has(parentId)) return { kind: 'note', candidateZohoId: index.noteCandidate.get(parentId) ?? null }
  return { kind: 'unknown', candidateZohoId: null }
}

export type Unresolvable = { attachment_id: string; reason: string; category: string }
export type FilesResult = {
  manifest: ManifestRow[]
  skipped: Record<string, number>
  unresolvable: Unresolvable[]
  counts: { eligible: number; text_only: number; skipped: number }
}

/** The manifest of eligible files, absolute paths, plus what was left and why. */
export function buildFilesManifest(exp: ZohoExport, attachmentsDir: string, tz: string): FilesResult {
  const disk = diskIndex(attachmentsDir)
  const parents = parentIndex(exp)
  const userEmail = new Map(exp.users.map((u) => [u['User ID'], u.Email.trim().toLowerCase() || null]))
  const manifest: ManifestRow[] = []
  const skipped: Record<string, number> = {}
  const unresolvable: Unresolvable[] = []
  for (const r of exp.attachments) {
    const onDisk = disk.get(r['File Name'].normalize('NFC'))
    const row: AttachmentRow = {
      attachmentId: r['Attachment Id'],
      fileName: r['File Name'],
      category: r.Category,
      parent: resolveParent(r['Parent ID'], parents),
    }
    const verdict = classifyAttachment(row, { exists: !!onDisk, size_bytes: onDisk?.size ?? null })
    if (verdict.kind === 'skip') {
      skipped[verdict.reason] = (skipped[verdict.reason] ?? 0) + 1
      unresolvable.push({ attachment_id: r['Attachment Id'], reason: verdict.reason, category: r.Category })
      continue
    }
    const entry = onDisk as { name: string; size: number }
    manifest.push({
      attachment_id: r['Attachment Id'],
      candidate_zoho_id: verdict.candidateZohoId,
      kind: verdict.kind,
      path: path.resolve(attachmentsDir, entry.name),
      original_name: originalNameOf(r['File Name']),
      mime: verdict.textOnly ? 'text/plain' : (mimeFor(r['File Name']) as string),
      size_bytes: entry.size,
      created_at: parseUsDateTime(r['Created Time'], tz),
      text_only: verdict.textOnly,
      owner_email: userEmail.get(r['Attachment Owner ID']) ?? null,
      ...(verdict.category ? { category: verdict.category } : {}),
    })
  }
  return {
    manifest,
    skipped,
    unresolvable,
    counts: { eligible: manifest.length, text_only: manifest.filter((m) => m.text_only).length, skipped: unresolvable.length },
  }
}

// ------------------------------------------------------- the upload plan
// What the files script writes for one manifest row (plan 052 §3.4): the row
// id is generated first so the object path and the row agree.

export type UploadPlan = {
  file_id: string
  candidate_id: string
  kind: FileKind
  storage_path: string
  original_name: string
  mime_type: string
  text_only: boolean
  created_at: string | null
  provider_ref: string
}

const EXT_FOR_MIME: Readonly<Record<string, string>> = {
  'application/pdf': 'pdf',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'text/plain': 'txt',
}

/** `LinkedIn profile capture (12 Mar 2024).txt` — the stored name of a text-only capture. */
export function profileCaptureName(createdAt: string | null, tz: string): string {
  return `LinkedIn profile capture (${createdAt ? longDate(createdAt, tz) : 'undated'}).txt`
}

export function planUpload(row: ManifestRow, candidateId: string, fileId: string, tz: string): UploadPlan {
  const ext = row.text_only ? 'txt' : (EXT_FOR_MIME[row.mime] ?? (path.extname(row.original_name).slice(1).toLowerCase() || 'bin'))
  return {
    file_id: fileId,
    candidate_id: candidateId,
    kind: row.kind,
    storage_path: `candidate/${candidateId}/${fileId}.${ext}`,
    original_name: row.text_only ? profileCaptureName(row.created_at, tz) : row.original_name,
    mime_type: row.text_only ? 'text/plain' : row.mime,
    text_only: row.text_only,
    created_at: row.created_at,
    provider_ref: row.attachment_id,
  }
}
