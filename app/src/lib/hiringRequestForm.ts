import { z } from 'zod'
import { cleanJobTitle, jobTitleProblem } from '@/lib/jobTitle'

/**
 * The hiring request form's fields, checked before anything is sent.
 * Decision D15 (migration 0117): the department and the hiring manager are
 * required — the database refuses a submitted request without them, with the
 * same words — and location and employment type are recorded when given.
 */
const optionalId = z.union([z.literal(''), z.string().uuid()])

export const requestFormInput = z.object({
  companyId: z.string().uuid('Choose a company.'),
  title: z
    .string()
    .max(120)
    .transform(cleanJobTitle)
    .superRefine((value, ctx) => {
      const problem = jobTitleProblem(value)
      if (problem) ctx.addIssue({ code: z.ZodIssueCode.custom, message: problem })
    }),
  reason: z.string().trim().max(2000, 'Keep the reason under 2000 characters.'),
  headcount: z.coerce.number().int().min(1, 'Headcount must be at least 1.'),
  targetStartDate: z.union([z.literal(''), z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a valid start date.')]),
  departmentId: z.string().uuid('Choose the department this hire is for.'),
  hiringManagerId: z.string().uuid('Choose the hiring manager for this hire.'),
  locationId: optionalId,
  employmentTypeKey: z.string().max(40),
})

export type RequestFormInput = z.infer<typeof requestFormInput>
