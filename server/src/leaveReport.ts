import { buildWorkbook, type Sheet } from './xlsx/workbook.js'
import {
  RECORD_COLUMNS,
  SUMMARY_COLUMNS,
  recordRow,
  sortPeople,
  sortRequests,
  summaryRow,
  type ReportPerson,
  type ReportRequest,
} from '../../shared/leaveReport.js'

/**
 * The finance leave export, as a workbook.
 *
 * Two sheets, because finance asks two different questions — "what was taken"
 * (every request, one row each, with its effect on the balance spelled out in
 * words) and "where does everyone stand" (one row per person). The wording of
 * the effect column is deliberately a sentence rather than a signed number:
 * this file is read by people who do not know the schema.
 *
 * The shape is Field Notebook's, down to the column headers and their widths,
 * because the maintainer asked for the same report. What differs is only what
 * this app names differently: a request's reference (Field Notebook's number
 * where the row came from it, this app's id otherwise) and "Former" where it
 * said "Archived".
 *
 * Pure: it is handed data and returns bytes, so the shape can be tested
 * without a database and without sending anything.
 */

const RECORD_WIDTHS = [13, 25, 17, 19, 14, 14, 17, 15, 13, 44]
const SUMMARY_WIDTHS = [25, 17, 19, 13, 18, 23, 23, 23, 35]

/** Dates are real dates in the file, not text; the rest is what it looks like. */
const RECORD_KINDS = ['text', 'text', 'text', 'text', 'date', 'date', 'text', 'number', 'text', 'text'] as const
// The last two hold a number or the words "Not applicable"; the writer falls
// back to text for a value that is not a number, so finance can still sum the
// column where there is something to sum.
const SUMMARY_KINDS = ['text', 'text', 'text', 'text', 'number', 'number', 'number', 'number', 'number'] as const

export function leaveReportSheets(input: {
  requests: ReadonlyArray<ReportRequest>
  people: ReadonlyArray<ReportPerson>
}): Sheet[] {
  return [
    {
      name: 'Leave records',
      columns: RECORD_COLUMNS.map((header, i) => ({ header, width: RECORD_WIDTHS[i], kind: RECORD_KINDS[i] })),
      rows: sortRequests(input.requests).map(recordRow),
    },
    {
      name: 'Balance summary',
      columns: SUMMARY_COLUMNS.map((header, i) => ({ header, width: SUMMARY_WIDTHS[i], kind: SUMMARY_KINDS[i] })),
      rows: sortPeople(input.people).map(summaryRow),
    },
  ]
}

export function buildLeaveReport(input: {
  requests: ReadonlyArray<ReportRequest>
  people: ReadonlyArray<ReportPerson>
}): Buffer {
  return buildWorkbook(leaveReportSheets(input))
}
