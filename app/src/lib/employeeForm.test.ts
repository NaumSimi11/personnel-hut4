import { describe, expect, it } from 'vitest'
import {
  emptyForm,
  employeeInput,
  hiddenSectionProblem,
  messageFor,
  personBasicsInput,
  prefillFromApplication,
  sectionsFor,
  shouldStartOnboarding,
  successLine,
  toPayload,
} from './employeeForm'

const TODAY = '2026-09-16'

describe('employee form', () => {
  it('starts empty, dated today, with the checklist on', () => {
    const f = emptyForm(TODAY)
    expect(f.startDate).toBe(TODAY)
    expect(f.startOnboarding).toBe(true)
    expect(f.fullName).toBe('')
    expect(f.employmentTypeKey).toBe('full_time')
  })

  it('pre-fills from an application: the candidate email is personal, the job decides company and title', () => {
    const f = prefillFromApplication(
      { candidateName: 'Ana Ilic', candidateEmail: 'ana@gmail.com', candidatePhone: '+389 70', jobTitle: 'Clerk', companyId: 'c1', startDate: '2026-10-01' },
      TODAY,
    )
    expect(f).toMatchObject({ fullName: 'Ana Ilic', personalEmail: 'ana@gmail.com', workEmail: '', phone: '+389 70', jobTitle: 'Clerk', companyId: 'c1', startDate: '2026-10-01' })
    expect(prefillFromApplication({ candidateName: 'B', candidateEmail: null, candidatePhone: null, jobTitle: 'X', companyId: 'c1' }, TODAY).startDate).toBe(TODAY)
  })

  it('shows the personal section to personal.view holders and pay to salary.propose holders, per company', () => {
    const viewer = { can: (company: string, cap: string) => company === 'c1' && (cap === 'personal.view' || cap === 'salary.propose') }
    expect(sectionsFor(viewer, 'c1')).toEqual({ personal: true, pay: true })
    expect(sectionsFor(viewer, 'c2')).toEqual({ personal: false, pay: false })
    expect(sectionsFor(viewer, '')).toEqual({ personal: false, pay: false })
  })

  it('starts the checklist for a recent or future start, not for a backfill', () => {
    expect(shouldStartOnboarding('2026-10-01', TODAY)).toBe(true)
    expect(shouldStartOnboarding('2026-09-01', TODAY)).toBe(true)
    expect(shouldStartOnboarding('2026-07-01', TODAY)).toBe(false)
  })

  it('refuses a short name, a bad email, no company and a pay amount that is not a number', () => {
    const base = { ...emptyForm(TODAY), fullName: 'Ana Ilic', companyId: '11111111-1111-4111-8111-111111111111', jobTitle: 'Clerk' }
    expect(employeeInput.safeParse(base).success).toBe(true)
    expect(employeeInput.safeParse({ ...base, fullName: 'A' }).success).toBe(false)
    expect(employeeInput.safeParse({ ...base, workEmail: 'nope' }).success).toBe(false)
    expect(employeeInput.safeParse({ ...base, companyId: '' }).success).toBe(false)
    expect(employeeInput.safeParse({ ...base, payAmount: 'lots' }).success).toBe(false)
    expect(employeeInput.safeParse({ ...base, payAmount: '-5' }).success).toBe(false)
    expect(employeeInput.safeParse({ ...base, payAmount: '1500', payCurrency: 'euro' }).success).toBe(false)
    expect(employeeInput.safeParse({ ...base, payAmount: '1500', payCurrency: 'eur' }).success).toBe(true)
  })

  it('builds the payload without blanks, nesting private and pay only when something is there', () => {
    const base = employeeInput.parse({ ...emptyForm(TODAY), fullName: 'Ana Ilic', companyId: '11111111-1111-4111-8111-111111111111', jobTitle: 'Clerk' })
    const plain = toPayload(base, {})
    expect(plain).toEqual({
      full_name: 'Ana Ilic',
      company_id: '11111111-1111-4111-8111-111111111111',
      job_title: 'Clerk',
      employment_type_key: 'full_time',
      start_date: TODAY,
      start_onboarding: true,
    })
    const full = toPayload(
      { ...base, workEmail: 'ana@x.test', nationalId: '1234567890123', bankName: 'NLB', bankAccountNumber: '2100', emergencyName: 'Petar', emergencyRelationship: 'brother', payAmount: '1500', payCurrency: 'EUR', payBasisKey: 'monthly' },
      { applicationId: 'app-1' },
    )
    expect(full).toMatchObject({
      work_email: 'ana@x.test',
      application_id: 'app-1',
      private: { national_id: '1234567890123', bank_name: 'NLB', bank_account_number: '2100', emergency_name: 'Petar', emergency_relationship: 'brother' },
      pay: { amount: '1500', currency: 'EUR', pay_basis_key: 'monthly' },
    })
    expect((full.private as Record<string, unknown>).birth_date).toBeUndefined()
  })

  it('shows the database sentence as it is and adds what to do from the error code', () => {
    expect(messageFor({ code: '42501', message: 'Personal details need personal.view in this company.' })).toBe(
      'Personal details need personal.view in this company. Leave that part empty or ask for the grant.',
    )
    expect(messageFor({ code: '23505', message: 'A person with this work email already exists — open their record and add the employment there.' })).toMatch(/already exists/)
    expect(messageFor({ code: '23P01', message: 'This person already has an employment period covering that date — end it first.' })).toMatch(/already has an employment/)
    expect(messageFor({ code: '22023', message: 'The birth date cannot be in the future.' })).toBe('The birth date cannot be in the future.')
    expect(messageFor({ code: 'PGRST301', message: 'weird' })).toBe('weird')
  })

  it('refuses to submit a filled section the viewer may not send, instead of dropping it', () => {
    const base = employeeInput.parse({ ...emptyForm(TODAY), fullName: 'Ana Ilic', companyId: '11111111-1111-4111-8111-111111111111', jobTitle: 'Clerk' })
    expect(hiddenSectionProblem(base, { personal: true, pay: true })).toBeNull()
    expect(hiddenSectionProblem({ ...base, nationalId: '1234' }, { personal: false, pay: true })).toMatch(/personal/i)
    expect(hiddenSectionProblem({ ...base, payAmount: '10' }, { personal: true, pay: false })).toMatch(/pay/i)
    expect(hiddenSectionProblem({ ...base, payAmount: '10' }, { personal: true, pay: true })).toBeNull()
  })

  it('exposes the identity rules for Edit details', () => {
    expect(personBasicsInput.safeParse({ fullName: 'Ana Ilic', preferredName: '', workEmail: '', personalEmail: 'x', phone: '' }).success).toBe(false)
    expect(personBasicsInput.safeParse({ fullName: 'Ana Ilic', preferredName: '', workEmail: 'ana@x.test', personalEmail: '', phone: '' }).success).toBe(true)
  })

  it('says what was created', () => {
    expect(successLine({ plan_id: 'p', compensation_record_id: null, already_hired: false })).toMatch(/checklist/)
    expect(successLine({ plan_id: null, compensation_record_id: 'c', already_hired: false })).toMatch(/pay proposal/)
    expect(successLine({ plan_id: null, compensation_record_id: null, already_hired: true })).toMatch(/already/)
  })
})
