/**
 * Filling a contract template with one person's facts.
 *
 * A contract is not a welcome note. If a placeholder has no value, the honest
 * outcomes are to refuse or to say so — never to quietly leave a gap, because
 * "a monthly salary of  EUR" is a document somebody signs and nobody reads
 * twice. So rendering reports what is missing instead of producing a plausible
 * blank, and the caller decides whether to go on.
 *
 * Shared because the editor needs to tell HR which fields exist and which of
 * them this person lacks, and the renderer needs the same answer at the moment
 * it makes the PDF.
 */
export type TemplateField = {
  readonly key: string
  readonly label: string
  /** Rendering refuses without it; a contract with a hole is worse than none. */
  readonly required: boolean
}

/** Everything a template may refer to. Adding one here is what makes it usable. */
export const TEMPLATE_FIELDS: readonly TemplateField[] = [
  { key: 'full_name', label: 'Full name', required: true },
  { key: 'national_id', label: 'National ID number', required: false },
  { key: 'address', label: 'Home address', required: false },
  { key: 'job_title', label: 'Job title', required: true },
  { key: 'department', label: 'Department', required: false },
  { key: 'company', label: 'Company', required: true },
  { key: 'company_legal_name', label: 'Company legal name', required: false },
  { key: 'start_date', label: 'Start date', required: true },
  { key: 'end_date', label: 'End date', required: false },
  { key: 'employment_type', label: 'Employment type', required: false },
  { key: 'salary', label: 'Salary', required: false },
  { key: 'currency', label: 'Currency', required: false },
  { key: 'manager', label: 'Manager', required: false },
  { key: 'work_email', label: 'Work email', required: false },
  { key: 'today', label: "Today's date", required: true },
]

const PLACEHOLDER = /\{\{\s*([a-z_]+)\s*\}\}/g

export type TemplateValues = Readonly<Record<string, string | null | undefined>>

export type RenderedTemplate = {
  readonly text: string
  /** Placeholders the template used that no field defines — a typo, usually. */
  readonly unknown: readonly string[]
  /** Required fields the template used that this person has no value for. */
  readonly missing: readonly string[]
}

/** Which placeholders a template body refers to, in the order they appear. */
export function placeholdersIn(body: string): string[] {
  const seen: string[] = []
  for (const match of body.matchAll(PLACEHOLDER)) {
    const key = match[1]
    if (!seen.includes(key)) seen.push(key)
  }
  return seen
}

/**
 * The body with values put in.
 *
 * A missing value leaves its placeholder visible rather than blank — so a
 * document that slips through shows `{{salary}}` where the number should be,
 * which anybody spots, instead of a gap nobody does.
 */
export function renderTemplate(body: string, values: TemplateValues): RenderedTemplate {
  const known = new Map(TEMPLATE_FIELDS.map((f) => [f.key, f]))
  const unknown: string[] = []
  const missing: string[] = []

  const text = body.replace(PLACEHOLDER, (whole, key: string) => {
    const field = known.get(key)
    if (!field) {
      if (!unknown.includes(key)) unknown.push(key)
      return whole
    }
    const value = (values[key] ?? '').toString().trim()
    if (value === '') {
      if (field.required && !missing.includes(key)) missing.push(key)
      return whole
    }
    return value
  })

  return { text, unknown, missing }
}

/** Whether this rendering is fit to be signed. */
export function canIssue(rendered: RenderedTemplate): boolean {
  return rendered.missing.length === 0 && rendered.unknown.length === 0
}

export function labelFor(key: string): string {
  return TEMPLATE_FIELDS.find((f) => f.key === key)?.label ?? key
}
