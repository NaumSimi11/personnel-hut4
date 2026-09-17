import { z } from 'zod'

/**
 * Kudos values and the Kudos page (plan 051): the form HR uses to record
 * a kudos on a colleague's behalf, the value form, and the month filter.
 * The rules live in migration 0044 (record_kudos / update_kudos /
 * save_kudos_value); these mirror them for the form.
 */

export const MESSAGE_MAX = 280

export const kudosInput = z
  .object({
    from_person_id: z.string().min(1, 'Say who gives the kudos.'),
    to_person_id: z.string().min(1, 'Say who receives it.'),
    message: z.string().trim().min(1, 'Write the message.').max(MESSAGE_MAX, `Keep it under ${MESSAGE_MAX} characters.`),
    value_id: z
      .string()
      .nullable()
      .transform((v) => (v ? v : null)),
    on_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the date.'),
  })
  .refine((k) => k.from_person_id !== k.to_person_id, { message: 'A kudos goes to someone else.', path: ['to_person_id'] })

export type KudosForm = z.input<typeof kudosInput>

export const kudosValueInput = z.object({
  name: z.string().trim().min(1, 'Give the value a name.').max(60, 'Keep the name under 60 characters.'),
  description: z.string().trim().max(300, 'Keep the description under 300 characters.'),
  active: z.boolean(),
})

export type KudosValue = { id: string; name: string; description: string | null; active: boolean; count?: number }

export type KudosAdminRow = {
  id: string
  message: string
  created_at: string
  from_person_id: string
  to_person_id: string
  from_name: string
  to_name: string
  value_id: string | null
  value_name: string | null
  posted_by_name: string | null
}

export type KudosOverview = {
  rows: KudosAdminRow[]
  months: { month: string; count: number }[]
  total: number
  values: KudosValue[]
  untagged: number
}

export const EMPTY_OVERVIEW: KudosOverview = { rows: [], months: [], total: 0, values: [], untagged: 0 }

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']

/** 'YYYY-MM' → 'September 2026'. */
export function monthLabel(month: string): string {
  const [y, m] = month.split('-')
  return `${MONTHS[Number(m) - 1] ?? m} ${y}`
}

/** The month filter: all first with the total, then each month with its count. */
export function monthOptions(months: { month: string; count: number }[], total: number): { value: string; label: string }[] {
  return [{ value: '', label: `All months (${total})` }, ...months.map((m) => ({ value: m.month, label: `${monthLabel(m.month)} (${m.count})` }))]
}
