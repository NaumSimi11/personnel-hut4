import { z } from 'zod'

/**
 * The Add employee form (plan 046): one screen, four sections, one call to
 * create_employee (migrations 0038 / 0039). The database decides every
 * rule; these helpers shape the form, gate the sections by capability,
 * build the payload and put the refusals into words.
 */

const DATE = /^\d{4}-\d{2}-\d{2}$/
const optionalEmail = z.union([z.literal(''), z.string().trim().toLowerCase().email('Enter a valid email or leave it empty.')])
const optionalText = (max: number) => z.string().trim().max(max)

/** Defaults the pickers start on; the database refuses an archived key. */
export const DEFAULT_EMPLOYMENT_TYPE = 'full_time'
export const DEFAULT_CURRENCY = 'EUR'
export const DEFAULT_PAY_BASIS = 'monthly'

/** Who the person is — shared by Add employee and Edit details. */
export const personBasicsInput = z.object({
  fullName: z.string().trim().min(2, 'Enter the full name.').max(120),
  preferredName: optionalText(60),
  workEmail: optionalEmail,
  personalEmail: optionalEmail,
  phone: optionalText(40),
})

export type PersonBasicsForm = z.infer<typeof personBasicsInput>

export const employeeInput = personBasicsInput
  .extend({
    companyId: z.string().uuid('Choose the employing company.'),
    jobTitle: z.string().trim().min(2, 'Enter the job title.').max(120),
    departmentId: z.string(),
    locationId: z.string(),
    employmentTypeKey: z.string(),
    managerId: z.string(),
    startDate: z.string().regex(DATE, 'Choose a start date.'),
    startOnboarding: z.boolean(),
    birthDate: z.union([z.literal(''), z.string().regex(DATE, 'The birth date is not a date.')]),
    addressLine: optionalText(200),
    nationalId: optionalText(32),
    bankName: optionalText(80),
    bankAccountNumber: optionalText(40),
    emergencyName: optionalText(120),
    emergencyRelationship: optionalText(60),
    emergencyPhone: optionalText(40),
    notes: optionalText(2000),
    payAmount: z.string().trim(),
    payCurrency: z.string().trim(),
    payBasisKey: z.string(),
    payNote: optionalText(500),
  })
  .superRefine((f, ctx) => {
    if (f.payAmount === '') return
    if (!/^\d+([.,]\d{1,2})?$/.test(f.payAmount) || Number(f.payAmount.replace(',', '.')) <= 0) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['payAmount'], message: 'The pay amount must be a number above zero.' })
    }
    if (!/^[A-Za-z]{3}$/.test(f.payCurrency)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['payCurrency'], message: 'Currency must be a three-letter code like EUR or MKD.' })
    }
    if (!f.payBasisKey) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['payBasisKey'], message: 'Choose how the amount is expressed.' })
    }
  })

export type EmployeeForm = z.infer<typeof employeeInput>

export function emptyForm(today: string): EmployeeForm {
  return {
    fullName: '',
    preferredName: '',
    workEmail: '',
    personalEmail: '',
    phone: '',
    companyId: '',
    jobTitle: '',
    departmentId: '',
    locationId: '',
    employmentTypeKey: DEFAULT_EMPLOYMENT_TYPE,
    managerId: '',
    startDate: today,
    startOnboarding: true,
    birthDate: '',
    addressLine: '',
    nationalId: '',
    bankName: '',
    bankAccountNumber: '',
    emergencyName: '',
    emergencyRelationship: '',
    emergencyPhone: '',
    notes: '',
    payAmount: '',
    payCurrency: DEFAULT_CURRENCY,
    payBasisKey: DEFAULT_PAY_BASIS,
    payNote: '',
  }
}

export type ApplicationTarget = {
  applicationId?: string
  candidateName: string
  candidateEmail: string | null
  candidatePhone: string | null
  jobTitle: string
  companyId: string
  /** The accepted offer's agreed date, when there is one. */
  startDate?: string
}

/**
 * The candidate's email is where they applied from — personal, not work
 * (the welcome note goes there, plan 050); HR types the work address once
 * the mailbox exists. A hire always gets its checklist, whatever the date.
 */
export function prefillFromApplication(target: ApplicationTarget, today: string): EmployeeForm {
  return {
    ...emptyForm(today),
    fullName: target.candidateName,
    personalEmail: target.candidateEmail ?? '',
    phone: target.candidatePhone ?? '',
    jobTitle: target.jobTitle,
    companyId: target.companyId,
    startDate: target.startDate ?? today,
    startOnboarding: true,
  }
}

export type Sections = { personal: boolean; pay: boolean }

/** Which sections this viewer may fill for the chosen company. */
export function sectionsFor(viewer: { can: (companyId: string, capability: string) => boolean }, companyId: string): Sections {
  if (!companyId) return { personal: false, pay: false }
  return { personal: viewer.can(companyId, 'personal.view'), pay: viewer.can(companyId, 'salary.propose') }
}

const BACKFILL_DAYS = 30

/** A checklist makes sense for someone starting now or soon; a backfill from months ago gets none by default. */
export function shouldStartOnboarding(startDate: string, today: string): boolean {
  const start = Date.parse(`${startDate}T00:00:00Z`)
  const now = Date.parse(`${today}T00:00:00Z`)
  if (Number.isNaN(start) || Number.isNaN(now)) return true
  return (now - start) / 86400000 <= BACKFILL_DAYS
}

const PRIVATE_FIELDS: [keyof EmployeeForm, string][] = [
  ['birthDate', 'birth_date'],
  ['addressLine', 'address_line'],
  ['nationalId', 'national_id'],
  ['bankName', 'bank_name'],
  ['bankAccountNumber', 'bank_account_number'],
  ['emergencyName', 'emergency_name'],
  ['emergencyRelationship', 'emergency_relationship'],
  ['emergencyPhone', 'emergency_phone'],
  ['notes', 'notes'],
]

const TOP_FIELDS: [keyof EmployeeForm, string][] = [
  ['preferredName', 'preferred_name'],
  ['workEmail', 'work_email'],
  ['personalEmail', 'personal_email'],
  ['phone', 'phone'],
  ['companyId', 'company_id'],
  ['jobTitle', 'job_title'],
  ['departmentId', 'department_id'],
  ['locationId', 'location_id'],
  ['employmentTypeKey', 'employment_type_key'],
  ['managerId', 'manager_id'],
  ['startDate', 'start_date'],
]

/** The filled string fields, under their database names; blanks left out. */
function pick(form: EmployeeForm, fields: [keyof EmployeeForm, string][]): Record<string, string> {
  return Object.fromEntries(
    fields.flatMap(([key, column]) => {
      const value = form[key]
      return typeof value === 'string' && value.trim() ? [[column, value.trim()]] : []
    }),
  )
}

function hasPrivate(form: EmployeeForm): boolean {
  return Object.keys(pick(form, PRIVATE_FIELDS)).length > 0
}

function hasPay(form: EmployeeForm): boolean {
  return form.payAmount.trim() !== ''
}

/**
 * A section the viewer may not send but has filled is refused before the
 * call, never dropped in silence (a company change can hide a filled part).
 */
export function hiddenSectionProblem(form: EmployeeForm, sections: Sections): string | null {
  if (!sections.personal && hasPrivate(form)) {
    return 'Personal details need personal.view in this company — clear that part or pick another company.'
  }
  if (!sections.pay && hasPay(form)) {
    return 'Proposing pay needs salary.propose in this company — clear the pay amount or pick another company.'
  }
  return null
}

/** The jsonb create_employee reads: blanks left out, private and pay nested only when filled. */
export function toPayload(form: EmployeeForm, opts: { applicationId?: string }): Record<string, unknown> {
  const top: Record<string, unknown> = {
    full_name: form.fullName.trim(),
    ...pick(form, TOP_FIELDS),
    start_onboarding: form.startOnboarding,
    ...(opts.applicationId ? { application_id: opts.applicationId } : {}),
  }
  const priv = pick(form, PRIVATE_FIELDS)
  const pay = hasPay(form)
    ? {
        amount: form.payAmount.trim().replace(',', '.'),
        currency: form.payCurrency.trim().toUpperCase(),
        pay_basis_key: form.payBasisKey,
        ...(form.payNote.trim() ? { note: form.payNote.trim() } : {}),
      }
    : null
  return {
    ...top,
    ...(Object.keys(priv).length ? { private: priv } : {}),
    ...(pay ? { pay } : {}),
  }
}

/**
 * create_employee already raises sentences; the error code says what kind.
 * 42501 = a capability is missing (say what to do about it); the rest are
 * shown as they are.
 */
export function messageFor(error: { code?: string; message: string }): string {
  if (error.code === '42501') return `${error.message} Leave that part empty or ask for the grant.`
  return error.message
}

export type CreateResult = { plan_id: string | null; compensation_record_id: string | null; already_hired: boolean }

/** The line on the success screen. */
export function successLine(result: CreateResult): string {
  if (result.already_hired) return 'This hire was already confirmed — nothing was created twice. Add details on the record if you typed any.'
  const parts = [
    'Employment recorded',
    ...(result.plan_id ? ['the onboarding checklist started'] : []),
    ...(result.compensation_record_id ? ['the pay proposal awaits a decision'] : []),
  ]
  return `${parts.join(', ')}.`
}
