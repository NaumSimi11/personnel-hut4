import { describe, expect, it } from 'vitest'
import { requestFormInput } from './hiringRequestForm'

const COMPANY = '10000000-0000-4000-8000-00000000000a'
const DEPT = 'e0000000-0000-4000-8000-00000000000a'
const HM = '20000000-0000-4000-8000-000000000001'
const LOC = 'f0000000-0000-4000-8000-00000000000a'

const base = {
  companyId: COMPANY,
  title: 'Backend developer',
  reason: '',
  headcount: 1,
  targetStartDate: '',
  hiringManagerId: HM,
  departmentId: DEPT,
  locationId: '',
  employmentTypeKey: '',
}

describe('requestFormInput (decision D15)', () => {
  it('accepts a request with a department and a hiring manager, location and type optional', () => {
    expect(requestFormInput.safeParse(base).success).toBe(true)
    const full = requestFormInput.safeParse({ ...base, locationId: LOC, employmentTypeKey: 'full_time' })
    expect(full.success && full.data.locationId).toBe(LOC)
  })

  it('requires the department', () => {
    const r = requestFormInput.safeParse({ ...base, departmentId: '' })
    expect(r.success ? '' : r.error.issues[0]?.message).toBe('Choose the department this hire is for.')
  })

  it('requires the hiring manager', () => {
    const r = requestFormInput.safeParse({ ...base, hiringManagerId: '' })
    expect(r.success ? '' : r.error.issues[0]?.message).toBe('Choose the hiring manager for this hire.')
  })

  it('still checks the title and headcount', () => {
    expect(requestFormInput.safeParse({ ...base, headcount: 0 }).success).toBe(false)
  })
})
