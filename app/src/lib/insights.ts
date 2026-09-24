import { z } from 'zod'
import { stageLabel } from '@/lib/dashboard'

/**
 * Recruitment insights (plan 067): the shape recruitment_insights (0086)
 * returns, validated at the boundary, and the lines the Reports page writes
 * from it — time to fill per opening, time to hire per person, the offer
 * acceptance rate, and the feed of stage changes. The database does the
 * counting; this file only presents it.
 */

const count = z.number().int().nonnegative().catch(0)
const date = z.string().nullable().catch(null)

const fillRow = z.object({
  job_id: z.string(),
  title: z.string(),
  status: z.string(),
  opened_on: date,
  target_start_date: date,
  headcount: count,
  applicants: count,
  hires: count,
  filled_on: date,
  days: count,
  late_days: count,
})

const hireRow = z.object({
  application_id: z.string(),
  candidate: z.string(),
  job_id: z.string(),
  job: z.string(),
  received_on: z.string(),
  hired_on: z.string(),
  days: count,
})

const activityRow = z.object({
  at: z.string(),
  application_id: z.string(),
  candidate: z.string(),
  job_id: z.string(),
  job: z.string(),
  from_stage: z.string().nullable().catch(null),
  to_stage: z.string().nullable().catch(null),
  actor: z.string().nullable().catch(null),
})

const offers = z.object({ extended: count, accepted: count, declined: count })

const insights = z.object({
  company_id: z.string(),
  from: z.string(),
  to: z.string(),
  can_see_candidates: z.boolean().catch(false),
  fill: z.array(fillRow).catch([]),
  hires: z.array(hireRow).catch([]),
  offers: offers.catch({ extended: 0, accepted: 0, declined: 0 }),
  activity: z.array(activityRow).catch([]),
})

export type RecruitmentInsights = z.infer<typeof insights>
export type FillRow = z.infer<typeof fillRow>
export type HireRow = z.infer<typeof hireRow>
export type ActivityRow = z.infer<typeof activityRow>
export type OfferCounts = z.infer<typeof offers>

export function parseInsights(raw: unknown): RecruitmentInsights {
  return insights.parse(raw)
}

/** The mean of the rows' days to one decimal, or a dash when there are none. */
export function averageDays(rows: ReadonlyArray<{ days: number }>): string {
  if (!rows.length) return '—'
  const mean = rows.reduce((sum, r) => sum + r.days, 0) / rows.length
  return (Math.round(mean * 10) / 10).toString()
}

/** Accepted out of the offers that got an answer; an offer still out has none yet. */
export function offerRate(o: OfferCounts): string {
  const answered = o.accepted + o.declined
  return answered ? `${Math.round((o.accepted / answered) * 100)}%` : '—'
}

function daysWord(n: number): string {
  return `${n} day${n === 1 ? '' : 's'}`
}

export function fillLine(r: FillRow): string {
  const head = r.filled_on ? `Filled in ${daysWord(r.days)}` : `Open ${daysWord(r.days)}`
  return r.late_days ? `${head} · ${daysWord(r.late_days)} past target start` : head
}

export function activitySentence(r: ActivityRow): string {
  const to = r.to_stage ? stageLabel(r.to_stage) : 'a new stage'
  const move = r.from_stage ? `from ${stageLabel(r.from_stage)} to ${to}` : `to ${to}`
  return `${r.candidate} moved ${move} for ${r.job}${r.actor ? ` by ${r.actor}` : ''}`
}
