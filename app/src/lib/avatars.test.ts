import { describe, expect, it } from 'vitest'
import { avatarObjectPath, avatarPublicUrl, validateAvatarFile } from './avatars'

describe('avatars', () => {
  it('stores photos under the person folder with a random name and the right extension', () => {
    const path = avatarObjectPath('11111111-1111-4111-8111-111111111111', 'image/webp')
    expect(path).toMatch(/^11111111-1111-4111-8111-111111111111\/[0-9a-f-]{36}\.webp$/)
    expect(avatarObjectPath('11111111-1111-4111-8111-111111111111', 'image/jpeg')).toMatch(/\.jpg$/)
  })
  it('builds the public URL from the bucket and path, or none without a path', () => {
    expect(avatarPublicUrl('p/x.webp')).toMatch(/\/storage\/v1\/object\/public\/avatars\/p\/x\.webp$/)
    expect(avatarPublicUrl(null)).toBeNull()
  })
  it('accepts images up to 2 MB and refuses the rest', () => {
    expect(validateAvatarFile({ type: 'image/png', size: 1000 })).toBeNull()
    expect(validateAvatarFile({ type: 'application/pdf', size: 1000 })).toMatch(/image/)
    expect(validateAvatarFile({ type: 'image/png', size: 3 * 1024 * 1024 })).toMatch(/2 MB/)
  })
})
