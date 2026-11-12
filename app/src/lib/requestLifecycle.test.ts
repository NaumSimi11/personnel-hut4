import { describe, expect, it } from 'vitest'
import { cancelNotice, lifecycleActions, reviewDate } from './requestLifecycle'

const hr = { personId: 'hr', can: (_c: string, cap: string) => cap === 'jobs.edit' }
const requester = { personId: 'me', can: () => false }
const bystander = { personId: 'x', can: () => false }
const req = (status: string) => ({ status, requested_by: 'me', company_id: 'A' })

describe('request lifecycle', () => {
  it('lets HR or the requester hold a pending or approved request', () => {
    expect(lifecycleActions(req('approved'), hr)).toEqual({ hold: true, resume: false, cancel: true })
    expect(lifecycleActions(req('submitted'), requester)).toEqual({ hold: true, resume: false, cancel: true })
    expect(lifecycleActions(req('approved'), bystander)).toEqual({ hold: false, resume: false, cancel: false })
  })

  it('offers resume on hold, and nothing on a final request', () => {
    expect(lifecycleActions(req('on_hold'), hr)).toEqual({ hold: false, resume: true, cancel: true })
    for (const s of ['filled', 'cancelled', 'rejected']) expect(lifecycleActions(req(s), hr)).toEqual({ hold: false, resume: false, cancel: false })
    expect(lifecycleActions(req('draft'), requester)).toEqual({ hold: false, resume: false, cancel: true })
  })

  it('counts the review date in days, across a month end', () => {
    expect(reviewDate('2026-11-25', 14)).toBe('2026-12-09')
    expect(reviewDate('2026-11-25', 0)).toBe('2026-11-25')
  })

  it('says what is left after a cancel', () => {
    expect(cancelNotice({ in_play: 0, jobs_closed: [] })).toBe('Request cancelled.')
    expect(cancelNotice({ in_play: 3, jobs_closed: ['j'] })).toBe(
      'Request cancelled. Its job is closed. 3 candidates are still in play — reject or withdraw them from Applicants.',
    )
  })
})
