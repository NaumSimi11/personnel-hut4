import { buildWorkbook, type Sheet } from './xlsx/workbook.js'

/**
 * The candidates export, as a workbook HR can line up against Zoho's
 * "Candidate-Job View".
 *
 * One row per application, like Zoho's view, plus one row for a candidate on
 * no job at all (Zoho's view has those too, with the job columns empty).
 * The ids are Zoho's display ids (`ZR_…_CAND`, `ZR_…_JOB`) where the record
 * came from Zoho and ours otherwise, so a lookup on either file finds the
 * other. Rows are sorted by the Zoho candidate number, then the job number,
 * so both files read in the same order once the old one is sorted that way.
 *
 * Pure: it is handed rows and returns bytes.
 */

export type ExportCandidate = {
  id: string
  full_name: string
  provider_ref: string | null
  current_title: string | null
}

export type ExportJob = {
  id: string
  title: string
  zoho_id: string | null
  department: string | null
  company: string | null
}

export type ExportApplication = {
  candidate_id: string
  job_id: string
  stage_key: string
  sub_status_key: string | null
}

export type ExportInput = {
  candidates: ReadonlyArray<ExportCandidate>
  jobs: ReadonlyArray<ExportJob>
  applications: ReadonlyArray<ExportApplication>
  /** Status key → the label HR set on Hiring → Labels. */
  statusLabels: Readonly<Record<string, string>>
}

export const EXPORT_COLUMNS = [
  'First name',
  'Last name',
  'Candidate ID',
  'Job Opening ID',
  'Job Opening',
  'Stage',
  'Status',
  'Current job title',
  'Department',
  'Company',
] as const

const COLUMN_WIDTHS = [18, 20, 16, 16, 40, 12, 26, 30, 24, 24]

/** The app's stage names (app/src/lib/stageStatuses.ts STAGE_LABEL). */
const STAGE_LABEL: Readonly<Record<string, string>> = {
  screening: 'Screening',
  interview: 'Interview',
  offer: 'Offered',
  hired: 'Hired',
}

/** What the old Zoho file said for a candidate on no job. */
const NO_JOB_STATUS = 'sourced'

export type ExportRow = readonly string[]

/** The last word is the surname; everything before it is the name. */
export function splitName(fullName: string): { first: string; last: string } {
  const words = fullName.trim().split(/\s+/).filter(Boolean)
  if (words.length < 2) return { first: words[0] ?? '', last: '' }
  return { first: words.slice(0, -1).join(' '), last: words.at(-1) ?? '' }
}

/** The number inside a Zoho display id, or Infinity for one of ours, so ours sort last. */
function idNumber(id: string): number {
  const match = /^ZR_(\d+)_/.exec(id)
  return match ? Number(match[1]) : Number.POSITIVE_INFINITY
}

function compareIds(a: string, b: string): number {
  if (a === b) return 0
  if (a === '') return -1
  if (b === '') return 1
  const byNumber = idNumber(a) - idNumber(b)
  return Number.isNaN(byNumber) || byNumber === 0 ? a.localeCompare(b) : byNumber
}

function candidateRow(c: ExportCandidate, job: ExportJob | null, app: ExportApplication | null, labels: ExportInput['statusLabels']): ExportRow {
  const { first, last } = splitName(c.full_name)
  // A candidate on no job reads "sourced", as Zoho's view (HR's column T) said for them.
  const statusKey = app ? app.sub_status_key : NO_JOB_STATUS
  const status = statusKey ? (labels[statusKey] ?? statusKey) : ''
  return [
    first,
    last,
    c.provider_ref ?? c.id,
    job ? (job.zoho_id ?? job.id) : '',
    job?.title ?? '',
    app ? (STAGE_LABEL[app.stage_key] ?? app.stage_key) : '',
    status,
    c.current_title ?? '',
    job?.department ?? '',
    job?.company ?? '',
  ]
}

export function exportRows(input: ExportInput): ExportRow[] {
  const jobsById = new Map(input.jobs.map((j) => [j.id, j]))
  const appsByCandidate = new Map<string, ExportApplication[]>()
  for (const a of input.applications) {
    appsByCandidate.set(a.candidate_id, [...(appsByCandidate.get(a.candidate_id) ?? []), a])
  }
  const rows = input.candidates.flatMap((c) => {
    const apps = appsByCandidate.get(c.id) ?? []
    if (!apps.length) return [candidateRow(c, null, null, input.statusLabels)]
    return apps.map((a) => candidateRow(c, jobsById.get(a.job_id) ?? null, a, input.statusLabels))
  })
  return [...rows].sort((a, b) => compareIds(a[2], b[2]) || compareIds(a[3], b[3]))
}

export function hiringExportSheets(input: ExportInput): Sheet[] {
  return [
    {
      name: 'Candidates',
      columns: EXPORT_COLUMNS.map((header, i) => ({ header, width: COLUMN_WIDTHS[i], kind: 'text' as const })),
      rows: exportRows(input),
    },
  ]
}

export function buildHiringExport(input: ExportInput): Buffer {
  return buildWorkbook(hiringExportSheets(input))
}

export function hiringExportFilename(today: string, filtered = false): string {
  return `peopleos-candidates-${filtered ? 'filtered-' : ''}${today}.xlsx`
}
