import { describe, expect, it } from 'vitest'
import { changeInput, currentPeriod, describeChanges, diffChanges, matchesFilter } from './employmentChanges'

const period = {
  job_title: 'Warehouse Lead',
  department_id: 'd1',
  location_id: null,
  manager_id: 'm1',
  employment_type_key: 'full_time',
}

describe('changeInput', () => {
  it('requires an effective date and trims the title', () => {
    const ok = changeInput.safeParse({
      effectiveDate: '2026-10-01',
      jobTitle: ' Ops Lead ',
      departmentId: 'd1',
      locationId: '',
      managerId: '',
      employmentTypeKey: 'full_time',
      reason: '',
    })
    expect(ok.success).toBe(true)
    if (ok.success) expect(ok.data.jobTitle).toBe('Ops Lead')
    expect(changeInput.safeParse({ effectiveDate: '', jobTitle: 'X', departmentId: '', locationId: '', managerId: '', employmentTypeKey: '', reason: '' }).success).toBe(false)
  })
})

describe('diffChanges', () => {
  it('includes only fields that differ from the period, with empty meaning cleared', () => {
    const out = diffChanges(period, {
      effectiveDate: '2026-10-01',
      jobTitle: 'Ops Lead',
      departmentId: 'd1',
      locationId: 'l1',
      managerId: '',
      employmentTypeKey: 'full_time',
      reason: '',
    })
    expect(out).toEqual({ job_title: 'Ops Lead', location_id: 'l1', manager_id: '' })
  })

  it('is empty when nothing changed', () => {
    expect(
      diffChanges(period, {
        effectiveDate: '2026-10-01',
        jobTitle: 'Warehouse Lead',
        departmentId: 'd1',
        locationId: '',
        managerId: 'm1',
        employmentTypeKey: 'full_time',
        reason: '',
      }),
    ).toEqual({})
  })
})

describe('describeChanges', () => {
  it('names each changed field with the human label of the new value', () => {
    const text = describeChanges(
      { job_title: 'Ops Lead', manager_id: 'm2', department_id: '' },
      { departments: { d2: 'Operations' }, locations: {}, people: { m2: 'Ana Ilic' }, employmentTypes: {} },
    )
    expect(text).toBe('Job title → Ops Lead · Manager → Ana Ilic · Department → none')
  })
})

describe('currentPeriod', () => {
  it('prefers the non-former period, else the latest by start date', () => {
    const periods = [
      { status: 'former', start_date: '2020-01-01', end_date: '2022-01-01' },
      { status: 'active', start_date: '2022-02-01', end_date: null },
    ]
    expect(currentPeriod(periods)?.status).toBe('active')
    expect(
      currentPeriod([
        { status: 'former', start_date: '2020-01-01', end_date: '2022-01-01' },
        { status: 'former', start_date: '2023-01-01', end_date: '2024-01-01' },
      ])?.start_date,
    ).toBe('2023-01-01')
    expect(currentPeriod([])).toBeNull()
  })
})

describe('matchesFilter', () => {
  const active = { status: 'active', start_date: '2024-01-01', end_date: null }
  const departing = { status: 'active', start_date: '2024-01-01', end_date: '2026-12-31' }
  const starting = { status: 'pre_start', start_date: '2026-12-01', end_date: null }
  const former = { status: 'former', start_date: '2020-01-01', end_date: '2021-01-01' }

  it('classifies each state', () => {
    expect(matchesFilter('active', active)).toBe(true)
    expect(matchesFilter('active', departing)).toBe(false)
    expect(matchesFilter('departing', departing)).toBe(true)
    expect(matchesFilter('starting', starting)).toBe(true)
    expect(matchesFilter('former', former)).toBe(true)
    expect(matchesFilter('none', null)).toBe(true)
    expect(matchesFilter('all', null)).toBe(true)
    expect(matchesFilter('active', null)).toBe(false)
  })
})

describe('currentPeriod with a future transfer', () => {
  it('keeps the active period current until the pre-start one actually starts', () => {
    const today = '2026-09-11'
    const periods = [
      { status: 'active', start_date: '2024-01-01', end_date: '2026-12-31' },
      { status: 'pre_start', start_date: '2027-01-01', end_date: null },
    ]
    expect(currentPeriod(periods, today)?.status).toBe('active')
    expect(currentPeriod([{ status: 'pre_start', start_date: '2027-01-01', end_date: null }], today)?.status).toBe('pre_start')
  })
})
