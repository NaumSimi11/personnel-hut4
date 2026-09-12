/**
 * People import (plan 032): CSV → rows the database validates
 * (import_people, migration 0024). The client only parses and maps
 * headers; every rule — duplicates, unknown departments, managers — is
 * decided by the function, and the preview is the same call as the commit.
 */

export const IMPORT_FIELDS = [
  'full_name',
  'work_email',
  'job_title',
  'start_date',
  'employment_type_key',
  'department',
  'location',
  'manager_email',
  'preferred_name',
  'phone',
] as const

export type ImportField = (typeof IMPORT_FIELDS)[number]
export type ImportRow = Partial<Record<ImportField, string>>

export const REQUIRED_FIELDS: ImportField[] = ['full_name', 'work_email', 'job_title', 'start_date']

export const IMPORT_TEMPLATE = [
  IMPORT_FIELDS.join(','),
  'Ana Ilic,ana.ilic@example.com,Operations Lead,2026-10-01,full_time,Operations,Skopje,boss@example.com,Ana,+389 70 000 000',
].join('\n')

const HEADER_ALIASES: Record<string, ImportField> = {
  name: 'full_name',
  fullname: 'full_name',
  full_name: 'full_name',
  email: 'work_email',
  workemail: 'work_email',
  work_email: 'work_email',
  title: 'job_title',
  jobtitle: 'job_title',
  job_title: 'job_title',
  position: 'job_title',
  start: 'start_date',
  startdate: 'start_date',
  start_date: 'start_date',
  type: 'employment_type_key',
  employmenttype: 'employment_type_key',
  employment_type: 'employment_type_key',
  employment_type_key: 'employment_type_key',
  department: 'department',
  team: 'department',
  location: 'location',
  office: 'location',
  manager: 'manager_email',
  manageremail: 'manager_email',
  manager_email: 'manager_email',
  preferredname: 'preferred_name',
  preferred_name: 'preferred_name',
  nickname: 'preferred_name',
  phone: 'phone',
  mobile: 'phone',
}

/** The delimiter is whichever of , ; or tab the header line uses most (EU Excel saves ;). */
function detectDelimiter(text: string): string {
  const header = text.split(/\r?\n/, 1)[0] ?? ''
  const counts = [',', ';', '\t'].map((d) => ({ d, n: header.split(d).length - 1 }))
  return counts.sort((a, b) => b.n - a.n)[0]?.n ? counts[0]!.d : ','
}

/** RFC-4180-ish: quoted fields, doubled quotes, CR/LF line ends, blank lines skipped. */
export function parseCsv(text: string): string[][] {
  const delimiter = detectDelimiter(text)
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i] as string
    if (quoted) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"'
          i++
        } else {
          quoted = false
        }
      } else {
        field += c
      }
      continue
    }
    if (c === '"') quoted = true
    else if (c === delimiter) {
      row.push(field)
      field = ''
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++
      row.push(field)
      field = ''
      if (row.some((f) => f.trim() !== '')) rows.push(row)
      row = []
    } else field += c
  }
  row.push(field)
  if (row.some((f) => f.trim() !== '')) rows.push(row)
  return rows
}

function normaliseHeader(h: string): ImportField | null {
  const key = h.trim().toLowerCase().replace(/[\s-]+/g, '_')
  return HEADER_ALIASES[key] ?? HEADER_ALIASES[key.replace(/_/g, '')] ?? null
}

/**
 * dd.mm.yyyy and dd/mm/yyyy become ISO only when unambiguous (a day above
 * 12); a date that could be either d/m or m/d is passed through so the
 * database refuses it rather than a wrong start date being imported.
 */
function isoDate(raw: string): string {
  const s = raw.trim()
  const dmy = /^(\d{1,2})[./](\d{1,2})[./](\d{4})$/.exec(s)
  if (!dmy) return s
  const [, a, b, year] = dmy
  const day = Number(a)
  const month = Number(b)
  if (day > 12 && month <= 12) return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`
  return s
}

export function shapeRows(table: string[][]): { rows: ImportRow[]; missing: ImportField[]; ignored: string[] } {
  const [header = [], ...body] = table
  const mapping = header.map(normaliseHeader)
  const ignored = header.filter((_, i) => mapping[i] === null).map((h) => h.trim())
  const present = new Set(mapping.filter((m): m is ImportField => m !== null))
  const missing = REQUIRED_FIELDS.filter((f) => !present.has(f))
  const rows = body.map((cells) => {
    const row: ImportRow = {}
    mapping.forEach((field, i) => {
      if (!field) return
      const value = (cells[i] ?? '').trim()
      if (!value) return
      row[field] = field === 'start_date' ? isoDate(value) : value
    })
    return row
  })
  return { rows, missing, ignored }
}

export type Verdict = { row: number; full_name: string; work_email: string; ok: boolean; problems: string[] }
export type ImportResult = { committed: boolean; ready: number; refused: number; rows: Verdict[] }

export function parseImportResult(raw: unknown): ImportResult {
  const obj = (raw ?? {}) as Partial<ImportResult>
  return {
    committed: obj.committed === true,
    ready: Number(obj.ready ?? 0),
    refused: Number(obj.refused ?? 0),
    rows: Array.isArray(obj.rows)
      ? obj.rows.map((r) => ({
          row: Number(r.row),
          full_name: String(r.full_name ?? ''),
          work_email: String(r.work_email ?? ''),
          ok: r.ok === true,
          problems: Array.isArray(r.problems) ? r.problems.map(String) : [],
        }))
      : [],
  }
}
