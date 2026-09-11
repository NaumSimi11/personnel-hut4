import { supabase } from '@/lib/supabase'

/**
 * Company logos live in the public `company-logos` bucket (migration 0011),
 * one object per company at {companyId}/logo.{ext}. The bucket enforces the
 * same type and size limits server-side; these checks just fail fast in the
 * form. Writes are admin-only via storage policies.
 */

export const LOGO_BUCKET = 'company-logos'
export const LOGO_MAX_BYTES = 1024 * 1024

const EXTENSION_BY_TYPE: Record<string, string> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
  'image/svg+xml': 'svg',
}

export const LOGO_ACCEPT = Object.keys(EXTENSION_BY_TYPE).join(',')

export function validateLogoFile(file: { type: string; size: number }): string | null {
  if (!EXTENSION_BY_TYPE[file.type]) return 'Logo must be a PNG, JPEG, WebP or SVG image.'
  if (file.size > LOGO_MAX_BYTES) return 'Logo must be 1 MB or smaller.'
  return null
}

/**
 * Every upload gets a fresh name: the public URL is cached by browsers and
 * the CDN, so replacing an object in place would show the old logo for up
 * to the cache lifetime. The previous object is removed after the upload.
 */
export function logoObjectPath(companyId: string, mimeType: string, version = Date.now()): string {
  return `${companyId}/logo-${version}.${EXTENSION_BY_TYPE[mimeType] ?? 'bin'}`
}

export function logoPublicUrl(path: string): string {
  return supabase.storage.from(LOGO_BUCKET).getPublicUrl(path).data.publicUrl
}

/** Upload a company's logo, remove the one it replaces, return the new path. */
export async function uploadCompanyLogo(
  companyId: string,
  file: File,
  previousPath: string | undefined,
): Promise<string> {
  const path = logoObjectPath(companyId, file.type)
  const { error } = await supabase.storage
    .from(LOGO_BUCKET)
    .upload(path, file, { contentType: file.type, cacheControl: '31536000' })
  if (error) throw new Error(error.message)
  if (previousPath && previousPath !== path) {
    const { error: removeError } = await supabase.storage.from(LOGO_BUCKET).remove([previousPath])
    if (removeError) console.warn('Old company logo not removed:', removeError.message)
  }
  return path
}
