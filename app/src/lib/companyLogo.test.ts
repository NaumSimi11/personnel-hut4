import { describe, expect, it } from 'vitest'
import { LOGO_MAX_BYTES, logoObjectPath, validateLogoFile } from './companyLogo'

describe('validateLogoFile', () => {
  it('accepts png, jpeg, webp and svg up to the size limit', () => {
    for (const type of ['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml']) {
      expect(validateLogoFile({ type, size: LOGO_MAX_BYTES })).toBeNull()
    }
  })

  it('rejects other file types with a readable message', () => {
    expect(validateLogoFile({ type: 'application/pdf', size: 10 })).toBe(
      'Logo must be a PNG, JPEG, WebP or SVG image.',
    )
  })

  it('rejects files over the size limit', () => {
    expect(validateLogoFile({ type: 'image/png', size: LOGO_MAX_BYTES + 1 })).toBe(
      'Logo must be 1 MB or smaller.',
    )
  })
})

describe('logoObjectPath', () => {
  it('keys the object by company and names it by type', () => {
    expect(logoObjectPath('c1', 'image/png', 1700000000000)).toBe('c1/logo-1700000000000.png')
    expect(logoObjectPath('c1', 'image/jpeg', 1)).toBe('c1/logo-1.jpg')
    expect(logoObjectPath('c1', 'image/webp', 1)).toBe('c1/logo-1.webp')
    expect(logoObjectPath('c1', 'image/svg+xml', 1)).toBe('c1/logo-1.svg')
  })

  it('gives every upload a new name so a replaced logo is never served from cache', () => {
    const first = logoObjectPath('c1', 'image/png')
    const second = logoObjectPath('c1', 'image/png', Date.now() + 1)
    expect(first).not.toBe(second)
    expect(first).toMatch(/^c1\/logo-\d+\.png$/)
  })
})
