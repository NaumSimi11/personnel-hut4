import { describe, expect, it } from 'vitest'
import { inWindow } from './careersRoutes.js'

describe('careers posting window', () => {
  it('shows a posting with no dates, and only inside its dates', () => {
    expect(inWindow(undefined, '2026-11-12')).toBe(true)
    expect(inWindow({}, '2026-11-12')).toBe(true)
    expect(inWindow({ publish_from: '2026-11-13' }, '2026-11-12')).toBe(false)
    expect(inWindow({ publish_until: '2026-11-11' }, '2026-11-12')).toBe(false)
    expect(inWindow({ publish_from: '2026-11-12', publish_until: '2026-11-12' }, '2026-11-12')).toBe(true)
  })
})
