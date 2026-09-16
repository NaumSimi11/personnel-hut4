import { describe, expect, it } from 'vitest'
import {
  correctionInput,
  fieldsFor,
  formFor,
  localProblem,
  messageFor,
  unchanged,
  type CorrectablePeriod,
} from './employmentCorrection'

const period: CorrectablePeriod = {
  start_date: '2026-01-01',
  job_title: 'Software Developer',
  employment_type_key: 'full_time',
  end_date: null,
  department_id: 'd1',
  location_id: null,
  manager_id: 'm1',
}

describe('employment correction', () => {
  it('starts from what the period says', () => {
    expect(formFor(period)).toEqual({
      startDate: '2026-01-01',
      jobTitle: 'Software Developer',
      employmentTypeKey: 'full_time',
      departmentId: 'd1',
      locationId: '',
      managerId: 'm1',
      reason: '',
    })
  })

  it('reads a missing employment type as no choice', () => {
    expect(formFor({ ...period, employment_type_key: null }).employmentTypeKey).toBe('')
  })

  it('refuses an empty job title and a malformed date', () => {
    expect(correctionInput.safeParse({ ...formFor(period), jobTitle: '  ' }).success).toBe(false)
    expect(correctionInput.safeParse({ ...formFor(period), startDate: '01/03/2024' }).success).toBe(false)
  })

  it('knows when nothing has changed, ignoring the reason', () => {
    expect(unchanged(period, formFor(period))).toBe(true)
    expect(unchanged(period, { ...formFor(period), reason: 'typo' })).toBe(true)
    expect(unchanged(period, { ...formFor(period), startDate: '2024-11-01' })).toBe(false)
    expect(unchanged(period, { ...formFor(period), jobTitle: 'Senior Developer' })).toBe(false)
    expect(unchanged(period, { ...formFor(period), departmentId: '' })).toBe(false)
    expect(unchanged(period, { ...formFor(period), managerId: 'm2' })).toBe(false)
  })

  it('sends only the structure fields that moved, null to clear', () => {
    expect(fieldsFor(period, formFor(period))).toEqual({})
    expect(fieldsFor(period, { ...formFor(period), departmentId: '' })).toEqual({ department_id: null })
    expect(fieldsFor(period, { ...formFor(period), locationId: 'l1', managerId: 'm2' })).toEqual({ location_id: 'l1', manager_id: 'm2' })
  })

  it('catches a start date after the end date before asking the database', () => {
    const closed = { ...period, end_date: '2025-12-31' }
    expect(localProblem(closed, { ...formFor(closed), startDate: '2026-06-01' })).toMatch(/after the end date/)
    expect(localProblem(closed, { ...formFor(closed), startDate: '2024-01-01' })).toBeNull()
    expect(localProblem(period, { ...formFor(period), startDate: '2030-01-01' })).toBeNull()
  })

  it('explains the overlap and the missing capability in words', () => {
    expect(messageFor({ message: 'conflicting key value violates exclusion constraint "no_overlapping_employment"' }))
      .toMatch(/overlaps another employment/)
    expect(messageFor({ message: 'Correcting an employment requires employment.edit' }))
      .toMatch(/need employment\.edit/)
    expect(messageFor({ message: 'something else entirely' })).toBe('something else entirely')
  })
})
