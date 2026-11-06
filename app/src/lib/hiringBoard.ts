import { INTERVIEW_KINDS } from '@/lib/interviews'
import type { HiringSummary, JobLite } from '@/lib/dashboard'
import { STAGES, STAGE_LABEL, type StageKey } from '@/lib/stageStatuses'

/**
 * The Home's hiring board and upcoming interviews (plan 067): the Zoho
 * Recruit home's per-job pipeline, one row per live job with a count in every
 * stage and the furthest stage anybody has reached marked, and the week's
 * interviews. Pure shaping of what the page reads; RLS decides what that is.
 */

export type BoardColumnKey = StageKey | 'closed'

/** In pipeline order. Rejected, withdrawn and closed-with-the-job are answers, not progress: one column. */
export const BOARD_COLUMNS: ReadonlyArray<{ key: BoardColumnKey; label: string }> = [
  ...STAGES.map((key) => ({ key, label: STAGE_LABEL[key] })),
  { key: 'closed', label: 'Closed' },
]

const PROGRESS: ReadonlyArray<BoardColumnKey> = STAGES

export type BoardRow = {
  jobId: string
  title: string
  company: string
  counts: Record<BoardColumnKey, number>
  total: number
  inPlay: number
  /** The furthest stage with anybody in it, closed excluded; null when everyone is closed. */
  furthest: BoardColumnKey | null
  daysOpen: number | null
}

const DAY_MS = 86_400_000

/** Whole calendar days from a date or timestamp to `today` (YYYY-MM-DD, UTC); never negative. */
export function daysSince(from: string | null | undefined, today: string): number | null {
  if (!from) return null
  const start = Date.parse(`${from.slice(0, 10)}T00:00:00Z`)
  const end = Date.parse(`${today}T00:00:00Z`)
  return Math.max(0, Math.round((end - start) / DAY_MS))
}

/** A hire stays in Hired; any other application no longer in play is Closed. */
function columnOf(stage: string, inPlay: boolean): BoardColumnKey | null {
  if (!(STAGES as ReadonlyArray<string>).includes(stage)) return null
  if (stage === 'hired') return 'hired'
  return inPlay ? (stage as StageKey) : 'closed'
}

function emptyCounts(): Record<BoardColumnKey, number> {
  return { screening: 0, interview: 0, offer: 0, hired: 0, closed: 0 }
}

/** One row per job anybody applied to, busiest first; a job the viewer cannot read keeps its row, untitled. */
export function jobBoard(summary: HiringSummary, jobs: ReadonlyArray<JobLite>, today: string): BoardRow[] {
  const known = new Map(jobs.map((j) => [j.id, j]))
  const rows = new Map<string, BoardRow>()
  for (const r of summary.by_job) {
    const column = columnOf(r.stage_key, r.in_play)
    if (!column) continue
    const job = known.get(r.job_id)
    const row = rows.get(r.job_id) ?? {
      jobId: r.job_id,
      title: job?.title ?? '—',
      company: job?.company?.name ?? '—',
      counts: emptyCounts(),
      total: 0,
      inPlay: 0,
      furthest: null,
      daysOpen: daysSince(job?.opened_at, today),
    }
    rows.set(r.job_id, {
      ...row,
      counts: { ...row.counts, [column]: row.counts[column] + r.count },
      total: row.total + r.count,
      inPlay: row.inPlay + (r.in_play ? r.count : 0),
    })
  }
  return [...rows.values()]
    .map((r) => ({ ...r, furthest: [...PROGRESS].reverse().find((k) => r.counts[k] > 0) ?? null }))
    .sort((a, b) => b.inPlay - a.inPlay || a.title.localeCompare(b.title))
}

export type InterviewLite = {
  id: string
  kind: string
  scheduled_at: string
  application: {
    id: string
    candidate: { full_name: string } | null
    job: { title: string; company: { name: string } | null } | null
  } | null
  panel: Array<{ person: { full_name: string } | null }>
}

export type UpcomingInterview = {
  id: string
  applicationId: string | null
  candidate: string
  job: string
  company: string
  kind: string
  scheduledAt: string
  /** The panel members the viewer may see; a hidden person is left out, not named. */
  panel: string[]
}

const KIND_LABELS: Record<string, string> = Object.fromEntries(INTERVIEW_KINDS.map((k) => [k.key, k.label]))

export function upcomingInterviews(rows: ReadonlyArray<InterviewLite>): UpcomingInterview[] {
  return [...rows]
    .sort((a, b) => a.scheduled_at.localeCompare(b.scheduled_at))
    .map((i) => ({
      id: i.id,
      applicationId: i.application?.id ?? null,
      candidate: i.application?.candidate?.full_name ?? 'Candidate',
      job: i.application?.job?.title ?? '—',
      company: i.application?.job?.company?.name ?? '—',
      kind: KIND_LABELS[i.kind] ?? 'Interview',
      scheduledAt: i.scheduled_at,
      panel: i.panel.flatMap((p) => (p.person ? [p.person.full_name] : [])),
    }))
}

const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

function localDayKey(d: Date): number {
  return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate())
}

/** "Today · 15:00", "Tomorrow · 09:05", else "Mon 28 Sep · 11:00" — in the viewer's own time zone. */
export function whenLabel(iso: string, now = new Date()): string {
  const d = new Date(iso)
  const time = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
  const offset = Math.round((localDayKey(d) - localDayKey(now)) / DAY_MS)
  if (offset === 0) return `Today · ${time}`
  if (offset === 1) return `Tomorrow · ${time}`
  return `${WEEKDAYS[d.getDay()]} ${d.getDate()} ${MONTHS[d.getMonth()]} · ${time}`
}
