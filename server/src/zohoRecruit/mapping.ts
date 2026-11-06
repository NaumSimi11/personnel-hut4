/**
 * The Zoho Recruit vocabulary → the app's (plan 052 §3.1), what the
 * Candidate-Job View import still needs: the candidate source. An unknown
 * value is a problem the extract reports, never a guess. Zoho's statuses
 * live in jobViewStatuses.ts.
 */

export class UnknownValueError extends Error {}

/** The 10 distinct `Source` values of Candidates_001.csv; blank is `imported`. */
export const SOURCE_TO_KEY: Readonly<Record<string, string>> = {
  'Head Hunt': 'head_hunt',
  'Imported using Resume Extractor': 'linkedin_profile',
  'Advertisement Linkedin': 'linkedin_ad',
  CareerSite: 'careers_page',
  'Advertisement External Career Pages': 'job_board',
  Advertisement: 'job_board',
  'Employee Referral': 'referral',
  'External Referral': 'referral',
  'Added by User': 'added_by_hand',
  None: 'imported',
}

export function mapSource(source: string): string {
  if (source === '') return 'imported'
  const found = Object.prototype.hasOwnProperty.call(SOURCE_TO_KEY, source) ? SOURCE_TO_KEY[source] : undefined
  if (!found) throw new UnknownValueError(`Unknown Zoho source "${source}"`)
  return found
}
