/**
 * HR's statuses (migration 0098): the keys HR writes in the orange column T,
 * "Status for this job" (lower-case j), of the Candidate-Job View. Zoho's own
 * column R ("Status for this Job") is kept on the row as written and decides
 * nothing.
 */
export const HR_STATUS_KEYS: ReadonlySet<string> = new Set([
  'sourced',
  'contacted',
  'interested',
  'no_response',
  'not_interested',
  'unqualified',
  'contact_in_future',
  'do_not_contact',
  'interview_to_schedule',
  'interview_hr',
  'interview_stakeholders',
  'interview_task',
  'rejected_by_hr',
  'rejected_after_interview',
  'withdrawn',
  'offer_made',
  'offer_declined',
  'hired',
])

/** The statuses that become the candidate's contact rule on import. */
export const DO_NOT_CONTACT_KEY = 'do_not_contact'
export const CONTACT_LATER_KEY = 'contact_in_future'

/**
 * HR's cell as a key: "Interview  Stakeholders", "Contacted" and a trailing
 * no-break space all read as the key HR meant. Null when it is no status.
 */
export function hrStatusKey(cell: string): string | null {
  const key = cell.replace(/ /g, ' ').trim().toLowerCase().replace(/\s+/g, '_')
  return HR_STATUS_KEYS.has(key) ? key : null
}
