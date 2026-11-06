import { describe, expect, it } from 'vitest'
import { SOURCE_TO_KEY, mapSource } from './mapping.js'

describe('mapSource', () => {
  it('maps the 10 source values', () => {
    expect(Object.keys(SOURCE_TO_KEY)).toHaveLength(10)
    expect(mapSource('Head Hunt')).toBe('head_hunt')
    expect(mapSource('Imported using Resume Extractor')).toBe('linkedin_profile')
    expect(mapSource('Advertisement Linkedin')).toBe('linkedin_ad')
    expect(mapSource('CareerSite')).toBe('careers_page')
    expect(mapSource('Advertisement External Career Pages')).toBe('job_board')
    expect(mapSource('Advertisement')).toBe('job_board')
    expect(mapSource('Employee Referral')).toBe('referral')
    expect(mapSource('External Referral')).toBe('referral')
    expect(mapSource('Added by User')).toBe('added_by_hand')
    expect(mapSource('None')).toBe('imported')
    expect(mapSource('')).toBe('imported')
  })

  it('throws on an unknown source', () => {
    expect(() => mapSource('LinkedIn')).toThrow(/unknown zoho source/i)
    expect(() => mapSource('head hunt')).toThrow(/unknown zoho source/i)
  })
})
