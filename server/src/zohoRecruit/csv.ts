import fs from 'node:fs'
import path from 'node:path'
import { parse } from 'csv-parse/sync'

/**
 * The Zoho Recruit export on disk (plan 052 §3): RFC 4180 CSVs with a BOM,
 * quoted multi-line fields and a header row. Every cell stays a string; a
 * ragged row is an error, never a shifted column.
 */

export type CsvRow = Record<string, string>

export function parseCsv(text: string): CsvRow[] {
  return parse(text, {
    bom: true,
    columns: true,
    skip_empty_lines: true,
    relax_quotes: false,
    trim: false,
  }) as CsvRow[]
}

export function readCsv(file: string): CsvRow[] {
  return parseCsv(fs.readFileSync(file, 'utf8'))
}

/** Split on a separator, trim, drop blanks. */
export function splitList(value: string, separator = ','): string[] {
  return value
    .split(separator)
    .map((part) => part.trim())
    .filter((part) => part !== '')
}

/** The tables the import reads, by the file name Zoho gives them. */
export const EXPORT_FILES = {
  candidates: 'Candidates_001.csv',
  associations: 'Associated_001.csv',
  jobs: 'Job Openings_001.csv',
  departments: 'Departments_001.csv',
  users: 'Users_001.csv',
  notes: 'Notes_001.csv',
  attachments: 'Attachments_001.csv',
  interviews: 'Interviews_001.csv',
  education: 'Candidates_Educational_Details.csv',
} as const

export type ZohoExport = { -readonly [K in keyof typeof EXPORT_FILES]: CsvRow[] }

export function readExport(dir: string): ZohoExport {
  const out: Partial<ZohoExport> = {}
  for (const [key, file] of Object.entries(EXPORT_FILES) as [keyof typeof EXPORT_FILES, string][]) {
    const full = path.join(dir, file)
    if (!fs.existsSync(full)) throw new Error(`Export table missing: ${full}`)
    out[key] = readCsv(full)
  }
  return out as ZohoExport
}
