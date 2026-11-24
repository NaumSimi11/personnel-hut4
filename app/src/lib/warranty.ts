import { longDate } from '@/lib/candidatePool'

/**
 * Warranty scans and dates on an item (24 Nov, migration 0130). Scans are
 * small on purpose: the database plan has 1 GB of storage for everything, so
 * photos are shrunk in the browser and every file is capped at 2 MB.
 */
export const WARRANTY_MAX_BYTES = 2 * 1024 * 1024
export const ACCEPTED_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'application/pdf'] as const
export const LONG_SIDE = 1800
export const SOON_DAYS = 60

export function fileProblem(file: { type: string; size: number }): string | null {
  if (!(ACCEPTED_TYPES as readonly string[]).includes(file.type)) return 'Upload an image or a PDF (JPG, PNG, WebP or PDF).'
  if (file.size > WARRANTY_MAX_BYTES) return 'The file is over 2 MB. Scan it at a lower resolution, or as a JPG.'
  return null
}

/** The size a photo is redrawn at: its long side at most LONG_SIDE, the shape kept. */
export function shrinkTo(width: number, height: number): { width: number; height: number } {
  const long = Math.max(width, height)
  if (long <= LONG_SIDE) return { width, height }
  const k = LONG_SIDE / long
  return { width: Math.round(width * k), height: Math.round(height * k) }
}

export function assetFilePath(companyId: string, assetId: string, fileName: string, id: string): string {
  const dot = fileName.lastIndexOf('.')
  const base = (dot > 0 ? fileName.slice(0, dot) : fileName).toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, 60)
  const ext = dot > 0 ? fileName.slice(dot + 1).toLowerCase().replace(/[^a-z0-9]/g, '') : 'bin'
  return `${companyId}/${assetId}/${id}-${base}.${ext}`
}

const DAY = 86_400_000

export function warrantyLine(until: string | null, today: string): { text: string; soon: boolean; ended: boolean } {
  if (!until) return { text: 'No warranty date', soon: false, ended: false }
  const days = Math.round((Date.parse(`${until}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / DAY)
  if (days < 0) return { text: `Warranty ended ${longDate(until)}`, soon: false, ended: true }
  if (days <= SOON_DAYS) return { text: `Warranty until ${longDate(until)} (${days} days left)`, soon: true, ended: false }
  return { text: `Warranty until ${longDate(until)}`, soon: false, ended: false }
}
