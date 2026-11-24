import { describe, expect, it } from 'vitest'
import { canMarkDidNotStart, departureInput, departureState, friendlyDepartureError } from './departure'

describe('departureState', () => {
  it('is "former" once the period status says so', () => {
    expect(departureState({ status: 'former', end_date: '2026-01-31' })).toBe('former')
  })

  it('is "departing" while an end date is set but the person is not yet former', () => {
    expect(departureState({ status: 'active', end_date: '2026-12-31' })).toBe('departing')
    expect(departureState({ status: 'pre_start', end_date: '2026-12-31' })).toBe('departing')
  })

  it('is "employed" with no end date', () => {
    expect(departureState({ status: 'active', end_date: null })).toBe('employed')
  })
})

describe('departureInput', () => {
  const startDate = '2026-01-15'

  it('accepts an end date on or after the start date and defaults the last working date to it', () => {
    const parsed = departureInput(startDate).safeParse({
      endDate: '2026-03-31',
      lastWorkingDate: '',
      reason: '',
    })
    expect(parsed.success).toBe(true)
    if (parsed.success) {
      expect(parsed.data.lastWorkingDate).toBe('2026-03-31')
      expect(parsed.data.reason).toBe('')
    }
  })

  it('rejects an end date before the start date', () => {
    const parsed = departureInput(startDate).safeParse({
      endDate: '2026-01-01',
      lastWorkingDate: '',
      reason: '',
    })
    expect(parsed.success).toBe(false)
    if (!parsed.success) {
      expect(parsed.error.issues[0]?.message).toBe('The end date cannot be before the start date.')
    }
  })

  it('rejects a last working date after the end date', () => {
    const parsed = departureInput(startDate).safeParse({
      endDate: '2026-03-31',
      lastWorkingDate: '2026-04-02',
      reason: '',
    })
    expect(parsed.success).toBe(false)
    if (!parsed.success) {
      expect(parsed.error.issues[0]?.message).toBe(
        'The last working date cannot be after the employment end date.',
      )
    }
  })

  it('requires an end date', () => {
    const parsed = departureInput(startDate).safeParse({ endDate: '', lastWorkingDate: '', reason: '' })
    expect(parsed.success).toBe(false)
    if (!parsed.success) expect(parsed.error.issues[0]?.message).toBe('Choose an employment end date.')
  })

  it('trims the reason and caps it at 500 characters', () => {
    const ok = departureInput(startDate).safeParse({
      endDate: '2026-03-31',
      lastWorkingDate: '',
      reason: '  Relocating abroad  ',
    })
    expect(ok.success).toBe(true)
    if (ok.success) expect(ok.data.reason).toBe('Relocating abroad')
    const long = departureInput(startDate).safeParse({
      endDate: '2026-03-31',
      lastWorkingDate: '',
      reason: 'x'.repeat(501),
    })
    expect(long.success).toBe(false)
  })
})

describe('friendlyDepartureError', () => {
  it('maps the capability refusal', () => {
    expect(
      friendlyDepartureError('Scheduling a departure requires departure.start in this company.'),
    ).toBe('You need the "Start offboarding" capability in this company.')
  })

  it('passes the readable RPC messages through', () => {
    expect(friendlyDepartureError('Choose an employment end date.')).toBe('Choose an employment end date.')
  })
})

describe('canMarkDidNotStart (24 Nov, audit B4)', () => {
  const today = '2026-11-24'
  it('is offered before the first day', () => {
    expect(canMarkDidNotStart({ status: 'pre_start', start_date: '2026-12-01' }, today)).toBe(true)
  })
  it('is offered on the first day and the week after it', () => {
    expect(canMarkDidNotStart({ status: 'active', start_date: today }, today)).toBe(true)
    expect(canMarkDidNotStart({ status: 'active', start_date: '2026-11-17' }, today)).toBe(true)
  })
  it('is not offered once the hire has been working more than a week, or is already out', () => {
    expect(canMarkDidNotStart({ status: 'active', start_date: '2026-11-16' }, today)).toBe(false)
    expect(canMarkDidNotStart({ status: 'former', start_date: today }, today)).toBe(false)
    expect(canMarkDidNotStart({ status: 'did_not_start', start_date: today }, today)).toBe(false)
  })
})
