import { z } from 'zod'

/**
 * Correcting an employment period (migration 0037) — the form's rules.
 *
 * A correction says the record never described reality, so unlike a change
 * (lib/employmentChanges.ts) it carries no effective date: the new facts are
 * simply what the period should have said all along.
 */

export const correctionInput = z.object({
  startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a start date.'),
  jobTitle: z.string().trim().min(1, 'A job title is required.').max(120),
  employmentTypeKey: z.string(),
  reason: z.string().trim().max(500),
})

export type CorrectionForm = z.infer<typeof correctionInput>

export type CorrectablePeriod = {
  start_date: string
  job_title: string
  employment_type_key: string | null
  end_date: string | null
}

export function formFor(period: CorrectablePeriod): CorrectionForm {
  return {
    startDate: period.start_date,
    jobTitle: period.job_title,
    employmentTypeKey: period.employment_type_key ?? '',
    reason: '',
  }
}

/** True when the form would leave the period exactly as it is. */
export function unchanged(period: CorrectablePeriod, form: CorrectionForm): boolean {
  return (
    form.startDate === period.start_date &&
    form.jobTitle.trim() === period.job_title &&
    form.employmentTypeKey === (period.employment_type_key ?? '')
  )
}

/**
 * The database is the authority on every rule here; these messages exist so
 * the obvious mistakes are answered without a round trip.
 */
export function localProblem(period: CorrectablePeriod, form: CorrectionForm): string | null {
  if (period.end_date && form.startDate > period.end_date) {
    return `The start date cannot be after the end date (${period.end_date}).`
  }
  return null
}

/** Turn a database error into something the person reading it can act on. */
export function messageFor(error: { message: string }): string {
  const m = error.message
  if (/employment\.edit/.test(m)) return 'You need employment.edit in this company to correct employment.'
  if (/no_overlapping_employment|overlaps another employment/.test(m)) {
    return 'That start date overlaps another employment this person holds. Correct or end the other period first.'
  }
  return m
}
