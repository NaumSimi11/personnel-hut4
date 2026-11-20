/**
 * "Export to Excel" on the Applicants list: the server builds the workbook
 * (server/src/hiringExport.ts) from what the caller may see, and the browser
 * only saves it.
 */

export const HIRING_EXPORT_ERROR = 'The export could not be built. Try again in a moment.'

const XLSX_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

export type ExportFile = { filename: string; bytes: Uint8Array }

/** Ask the server for the workbook; throws an Error whose message is fit to show. */
/** The Applicants list's filters, as the list holds them. */
export type ExportFilter = { stage: string; status: string; companyId: string; search: string }

/** With a filter, the file holds what the list shows; without one, everyone (candidates on no job included). */
export async function fetchHiringExport(accessToken: string, today: string, fetcher: typeof fetch = fetch, filter?: ExportFilter): Promise<ExportFile> {
  const res = await fetcher('/api/reports/hiring-export', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${accessToken}` },
    body: JSON.stringify(filter ? { today, scope: 'filtered', filter } : { today, scope: 'everyone' }),
  })
  const body = (await res.json().catch(() => ({}))) as { error?: string; filename?: string; base64?: string }
  if (!res.ok) throw new Error(body.error ?? HIRING_EXPORT_ERROR)
  if (typeof body.base64 !== 'string' || typeof body.filename !== 'string') throw new Error(HIRING_EXPORT_ERROR)
  return { filename: body.filename, bytes: Uint8Array.from(atob(body.base64), (c) => c.charCodeAt(0)) }
}

/** Hand the file to the browser's downloads. */
export function saveExportFile(file: ExportFile): void {
  const url = URL.createObjectURL(new Blob([file.bytes], { type: XLSX_TYPE }))
  const link = document.createElement('a')
  link.href = url
  link.download = file.filename
  link.click()
  URL.revokeObjectURL(url)
}
