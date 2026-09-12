import { z } from 'zod'

/**
 * Recruitment reporting (plan 021): the shape the recruitment_report RPC
 * returns, validated at the boundary, plus the small pure helpers the page
 * needs. The database does the counting; this file only presents it.
 */

export const STAGE_ORDER = ['new', 'screening', 'interview', 'offer', 'hired', 'rejected', 'withdrawn'] as const
export type Stage = (typeof STAGE_ORDER)[number]

const count = z.number().int().nonnegative().catch(0)

const stageCounts = z.object(
  Object.fromEntries(STAGE_ORDER.map((s) => [s, count])) as Record<Stage, typeof count>,
)

const report = z.object({
  company_id: z.string(),
  from: z.string(),
  to: z.string(),
  kpis: z.object({
    open_roles: count,
    active_candidates: count,
    received: count,
    hires: count,
    median_days_to_hire: z.number().nullable().catch(null),
    avg_days_to_hire: z.number().nullable().catch(null),
  }),
  funnel: z.array(
    z.object({
      job_id: z.string(),
      title: z.string(),
      status: z.string(),
      received: count,
      stages: stageCounts,
      hired: count,
    }),
  ),
  sources: z.array(z.object({ source: z.string(), received: count, interviewed: count, hired: count })),
  attention: z.object({ overdue_next_actions: count, unassigned: count, stale: count }),
})

export type RecruitmentReport = z.infer<typeof report>

export function parseReport(raw: unknown): RecruitmentReport {
  return report.parse(raw)
}

export function conversion(part: number, whole: number): string {
  if (!whole) return '—'
  return `${Math.round((part / whole) * 100)}%`
}

function isoDate(d: Date): string {
  return d.toISOString().slice(0, 10)
}

/** The last 90 days, ending today. */
export function defaultRange(today = new Date()): { from: string; to: string } {
  const from = new Date(today)
  from.setUTCDate(from.getUTCDate() - 90)
  return { from: isoDate(from), to: isoDate(today) }
}

export function csvCell(value: string | number): string {
  let text = String(value)
  // A leading = + - @ (or tab/CR) would be executed as a formula by Excel
  // and LibreOffice; a leading apostrophe makes it plain text.
  if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`
  return /[",\n']/.test(text) ? `"${text.replace(/"/g, '""')}"` : text
}

export function funnelCsv(data: RecruitmentReport): string {
  const header = ['Job', 'Status', 'Received', ...STAGE_ORDER.map((s) => s[0]!.toUpperCase() + s.slice(1))]
  const rows = data.funnel.map((f) => [f.title, f.status, f.received, ...STAGE_ORDER.map((s) => f.stages[s])])
  return [header, ...rows].map((r) => r.map(csvCell).join(',')).join('\n')
}
