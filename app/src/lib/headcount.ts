export type HeadcountSource = { request?: { headcount: number } | null; custom?: Record<string, unknown> | null }

/**
 * How many hires a job wants: its hiring request's headcount, else the
 * number Zoho Recruit kept on the job, else one — app.job_headcount (0090)
 * reads it the same way, and fills the job when the hires reach it.
 */
export function jobHeadcount(job: HeadcountSource): number {
  if (job.request?.headcount) return Math.max(1, job.request.headcount)
  const zoho = (job.custom?.zoho ?? null) as { headcount?: unknown } | null
  const raw = Number(zoho?.headcount)
  return Number.isInteger(raw) && raw > 0 ? raw : 1
}
