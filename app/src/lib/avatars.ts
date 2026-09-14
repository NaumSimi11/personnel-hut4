import { supabase } from '@/lib/supabase'

/**
 * Profile photos (plan 040). Objects live in the public `avatars` bucket at
 * {person_id}/{uuid}.{ext}; people.avatar_url keeps the object path and the
 * URL is built here. The browser squares and shrinks the image before it
 * leaves the machine — a 12 MB phone photo becomes a 256px WebP — and
 * set_avatar (self or someone who may edit the record) writes the path.
 */

export const AVATAR_BUCKET = 'avatars'
export const AVATAR_MAX_BYTES = 2 * 1024 * 1024
export const AVATAR_SIZE = 256
export const AVATAR_ACCEPT = 'image/png,image/jpeg,image/webp'

const EXTENSION_BY_TYPE: Record<string, string> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp' }

export function validateAvatarFile(file: { type: string; size: number }): string | null {
  if (!EXTENSION_BY_TYPE[file.type]) return 'Choose an image (PNG, JPEG or WebP).'
  if (file.size > AVATAR_MAX_BYTES) return 'The image must be under 2 MB.'
  return null
}

export function avatarObjectPath(personId: string, mimeType: string): string {
  return `${personId}/${crypto.randomUUID()}.${EXTENSION_BY_TYPE[mimeType] ?? 'webp'}`
}

export function avatarPublicUrl(path: string | null | undefined): string | null {
  if (!path) return null
  return supabase.storage.from(AVATAR_BUCKET).getPublicUrl(path).data.publicUrl
}

/** Centre-crop to a square and shrink to AVATAR_SIZE, as WebP; the original never leaves the browser. */
export async function squareImage(file: File, size = AVATAR_SIZE): Promise<Blob> {
  const bitmap = await createImageBitmap(file)
  const side = Math.min(bitmap.width, bitmap.height)
  const sx = (bitmap.width - side) / 2
  const sy = (bitmap.height - side) / 2
  const canvas = document.createElement('canvas')
  canvas.width = size
  canvas.height = size
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('This browser cannot process images.')
  ctx.drawImage(bitmap, sx, sy, side, side, 0, 0, size, size)
  bitmap.close()
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('Could not encode the image.'))), 'image/webp', 0.86)
  })
}

/** Upload a new photo for a person and point their record at it; the previous file is removed afterwards. */
export async function uploadAvatar(personId: string, file: File): Promise<string> {
  const problem = validateAvatarFile(file)
  if (problem) throw new Error(problem)
  const blob = await squareImage(file)
  const path = avatarObjectPath(personId, 'image/webp')
  const { error: uploadError } = await supabase.storage.from(AVATAR_BUCKET).upload(path, blob, { contentType: 'image/webp', cacheControl: '31536000' })
  if (uploadError) throw new Error(friendlyAvatarError(uploadError.message))
  const { data, error } = await supabase.rpc('set_avatar', { p_person_id: personId, p_path: path })
  if (error) {
    await supabase.storage.from(AVATAR_BUCKET).remove([path])
    throw new Error(friendlyAvatarError(error.message))
  }
  const previous = (data as { previous?: string | null } | null)?.previous
  if (previous) await supabase.storage.from(AVATAR_BUCKET).remove([previous])
  return path
}

export async function removeAvatar(personId: string): Promise<void> {
  const { data, error } = await supabase.rpc('set_avatar', { p_person_id: personId })
  if (error) throw new Error(friendlyAvatarError(error.message))
  const previous = (data as { previous?: string | null } | null)?.previous
  if (previous) await supabase.storage.from(AVATAR_BUCKET).remove([previous])
}

function friendlyAvatarError(message: string): string {
  if (/row-level security|violates|policy/i.test(message)) return 'You may only change your own photo, or the photo of someone whose record you edit.'
  return message
}
