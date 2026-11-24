import { describe, expect, it } from 'vitest'
import { WARRANTY_MAX_BYTES, assetFilePath, fileProblem, shrinkTo, warrantyLine } from './warranty'

describe('warranty scans and dates (24 Nov)', () => {
  it('takes images and PDFs up to 2 MB', () => {
    expect(WARRANTY_MAX_BYTES).toBe(2 * 1024 * 1024)
    expect(fileProblem({ type: 'image/jpeg', size: 500_000 })).toBeNull()
    expect(fileProblem({ type: 'application/pdf', size: 1_900_000 })).toBeNull()
    expect(fileProblem({ type: 'application/pdf', size: 3_000_000 })).toMatch(/2 MB/)
    expect(fileProblem({ type: 'application/zip', size: 10 })).toMatch(/image or a PDF/)
  })

  it('shrinks a large photo to at most 1,800 px on its long side, keeping its shape', () => {
    expect(shrinkTo(4000, 3000)).toEqual({ width: 1800, height: 1350 })
    expect(shrinkTo(1200, 3600)).toEqual({ width: 600, height: 1800 })
    expect(shrinkTo(800, 600)).toEqual({ width: 800, height: 600 })
  })

  it('stores a scan under its company and item, with a safe file name', () => {
    expect(assetFilePath('c1', 'a1', 'Račun (garancija).JPG', 'u1')).toBe('c1/a1/u1-ra-un-garancija-.jpg')
  })

  it('says when the warranty ends, and flags the last 60 days', () => {
    const today = '2026-11-24'
    expect(warrantyLine(null, today)).toEqual({ text: 'No warranty date', soon: false, ended: false })
    expect(warrantyLine('2027-06-01', today)).toEqual({ text: 'Warranty until 1 Jun 2027', soon: false, ended: false })
    expect(warrantyLine('2026-12-24', today)).toEqual({ text: 'Warranty until 24 Dec 2026 (30 days left)', soon: true, ended: false })
    expect(warrantyLine('2026-11-01', today)).toEqual({ text: 'Warranty ended 1 Nov 2026', soon: false, ended: true })
  })
})
