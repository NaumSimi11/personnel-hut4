import { describe, expect, it } from 'vitest'
import {
  DEFAULT_CRITERIA,
  INTERVIEW_KINDS,
  RECOMMENDATIONS,
  criteriaFor,
  interviewImportLine,
  interviewInput,
  interviewUnresolvedPanelLine,
  scorecardInput,
  zohoInterviewMeta,
} from './interviews'

describe('interviewInput', () => {
  it('accepts a kind, a future-or-past date-time, a duration and optional location', () => {
    const parsed = interviewInput.safeParse({
      kind: 'technical',
      scheduledAt: '2026-10-01T10:00',
      durationMinutes: '45',
      location: ' Meet link ',
      panel: ['p1', 'p2'],
    })
    expect(parsed.success).toBe(true)
    if (parsed.success) {
      expect(parsed.data.durationMinutes).toBe(45)
      expect(parsed.data.location).toBe('Meet link')
    }
  })

  it('requires a date-time and a sensible duration', () => {
    expect(interviewInput.safeParse({ kind: 'phone', scheduledAt: '', durationMinutes: '30', location: '', panel: [] }).success).toBe(false)
    const long = interviewInput.safeParse({ kind: 'phone', scheduledAt: '2026-10-01T10:00', durationMinutes: '600', location: '', panel: [] })
    expect(long.success).toBe(false)
    if (!long.success) expect(long.error.issues[0]?.message).toBe('Duration must be between 15 minutes and 8 hours.')
  })

  it('knows the five interview kinds', () => {
    expect(INTERVIEW_KINDS.map((k) => k.key)).toEqual(['phone', 'technical', 'panel', 'final', 'other'])
  })
})

describe('criteriaFor', () => {
  it('uses the job criteria when set, otherwise the defaults', () => {
    expect(criteriaFor([{ id: 'x', label: 'X' }])).toEqual([{ id: 'x', label: 'X' }])
    expect(criteriaFor([])).toEqual(DEFAULT_CRITERIA)
    expect(criteriaFor(null)).toEqual(DEFAULT_CRITERIA)
  })

  it('ignores malformed entries', () => {
    expect(criteriaFor([{ id: 'ok', label: 'OK' }, { nope: true }, 'junk'])).toEqual([{ id: 'ok', label: 'OK' }])
  })
})

describe('scorecardInput', () => {
  const criteria = [
    { id: 'skills', label: 'Role skills' },
    { id: 'comm', label: 'Communication' },
  ]

  it('requires a 1–4 rating for every criterion and a recommendation', () => {
    const ok = scorecardInput(criteria).safeParse({
      ratings: { skills: { rating: 3, evidence: 'Built a similar system' }, comm: { rating: 4, evidence: '' } },
      recommendation: 'yes',
      summary: '',
    })
    expect(ok.success).toBe(true)
    if (ok.success) {
      expect(ok.data.ratings).toEqual([
        { criterion_id: 'skills', label: 'Role skills', rating: 3, evidence: 'Built a similar system' },
        { criterion_id: 'comm', label: 'Communication', rating: 4, evidence: '' },
      ])
    }
  })

  it('rejects a missing rating with the criterion named', () => {
    const missing = scorecardInput(criteria).safeParse({
      ratings: { skills: { rating: 3, evidence: '' } },
      recommendation: 'yes',
      summary: '',
    })
    expect(missing.success).toBe(false)
    if (!missing.success) expect(missing.error.issues[0]?.message).toBe('Rate "Communication" from 1 to 4.')
  })

  it('rejects a rating outside 1–4 and an unknown recommendation', () => {
    expect(
      scorecardInput(criteria).safeParse({
        ratings: { skills: { rating: 5, evidence: '' }, comm: { rating: 2, evidence: '' } },
        recommendation: 'yes',
        summary: '',
      }).success,
    ).toBe(false)
    expect(
      scorecardInput(criteria).safeParse({
        ratings: { skills: { rating: 3, evidence: '' }, comm: { rating: 2, evidence: '' } },
        recommendation: 'maybe',
        summary: '',
      }).success,
    ).toBe(false)
  })

  it('offers four recommendations with no middle option', () => {
    expect(RECOMMENDATIONS.map((r) => r.key)).toEqual(['strong_no', 'no', 'yes', 'strong_yes'])
  })
})

describe('zohoInterviewMeta', () => {
  it('reads name, outcome and the unresolved interviewers from custom.zoho', () => {
    expect(
      zohoInterviewMeta({ zoho: { id: '1', name: 'Level 1 Interview', outcome: 'Move to next round', interviewers: ['Ana', 'Bo'] } }),
    ).toEqual({ name: 'Level 1 Interview', outcome: 'Move to next round', interviewers: ['Ana', 'Bo'] })
  })

  it('treats blanks and junk as absent, and no zoho object as nothing', () => {
    expect(zohoInterviewMeta({ zoho: { name: '  ', outcome: 7, interviewers: ['', 3, ' Cy '] } })).toEqual({
      name: null,
      outcome: null,
      interviewers: ['Cy'],
    })
    expect(zohoInterviewMeta({ zoho: { name: 'Phone' } })).toEqual({ name: 'Phone', outcome: null, interviewers: [] })
    expect(zohoInterviewMeta({})).toBeNull()
    expect(zohoInterviewMeta({ zoho: [] })).toBeNull()
    expect(zohoInterviewMeta(null)).toBeNull()
    expect(zohoInterviewMeta('junk')).toBeNull()
  })
})

describe('interviewImportLine', () => {
  it('says where an imported interview came from, its Zoho name and its outcome', () => {
    expect(
      interviewImportLine({ provider: 'zoho_recruit', custom: { zoho: { name: 'Level 2 Interview', outcome: 'Hired' } } }),
    ).toBe('Imported from Zoho Recruit · Level 2 Interview · outcome: Hired')
  })

  it('falls back to "Interview" and a dash when the name or outcome is missing', () => {
    expect(interviewImportLine({ provider: 'zoho_recruit', custom: { zoho: { id: '1' } } })).toBe(
      'Imported from Zoho Recruit · Interview · outcome: —',
    )
    expect(interviewImportLine({ provider: 'zoho_recruit', custom: {} })).toBe('Imported from Zoho Recruit · Interview · outcome: —')
  })

  it('is nothing for an interview scheduled here', () => {
    expect(interviewImportLine({ provider: null, custom: {} })).toBeNull()
    expect(interviewImportLine({ provider: 'e2e', custom: { zoho: { name: 'X' } } })).toBeNull()
  })
})

describe('interviewUnresolvedPanelLine', () => {
  it('names the interviewers the import could not link, and is silent when there are none', () => {
    expect(
      interviewUnresolvedPanelLine({ provider: 'zoho_recruit', custom: { zoho: { interviewers: ['Ana Ilieva', 'Bo Petrov'] } } }),
    ).toBe('Also on the panel: Ana Ilieva, Bo Petrov')
    expect(interviewUnresolvedPanelLine({ provider: 'zoho_recruit', custom: { zoho: { interviewers: [] } } })).toBeNull()
    expect(interviewUnresolvedPanelLine({ provider: 'zoho_recruit', custom: {} })).toBeNull()
    expect(interviewUnresolvedPanelLine({ provider: null, custom: { zoho: { interviewers: ['Ana'] } } })).toBeNull()
  })
})
