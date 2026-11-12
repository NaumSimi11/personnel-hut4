/**
 * The pipeline board (0105; spec 5.1–5.9, screen 9.8): the spec's stages as
 * columns over the four stages and HR's statuses. Each column says which
 * applications it holds and which status a card dropped on it gets. Hired is
 * reached through the offer only, so nothing is dropped there.
 */
export type BoardApplication = {
  id: string
  stage_key: string
  sub_status_key: string | null
  in_play: boolean
}
export type OptionalStatus = 'interview_task' | 'interview_hr' | 'interview_stakeholders'
export type BoardColumn = {
  key: string
  label: string
  owner: string
  target: string | null
  optional: OptionalStatus | null
  holds: (a: BoardApplication) => boolean
}

const SPECIAL_SCREENING = new Set(['applied', 'shortlisted', 'contact'])
const OPTIONAL_INTERVIEW = new Set<string>(['interview_task', 'interview_hr', 'interview_stakeholders'])

export const BOARD_COLUMNS: ReadonlyArray<BoardColumn> = [
  { key: 'applied', label: 'Applied', owner: 'Arrives from the careers page', target: 'applied', optional: null,
    holds: (a) => a.in_play && a.stage_key === 'screening' && a.sub_status_key === 'applied' },
  { key: 'screening', label: 'Screening', owner: 'Recruiter', target: 'sourced', optional: null,
    holds: (a) => a.in_play && a.stage_key === 'screening' && !SPECIAL_SCREENING.has(a.sub_status_key ?? '') },
  { key: 'shortlisted', label: 'Shortlisted', owner: 'Hiring manager', target: 'shortlisted', optional: null,
    holds: (a) => a.in_play && a.stage_key === 'screening' && (a.sub_status_key === 'shortlisted' || a.sub_status_key === 'contact') },
  { key: 'test', label: 'Technical / Skills test', owner: 'Assessor', target: 'interview_task', optional: 'interview_task',
    holds: (a) => a.in_play && a.sub_status_key === 'interview_task' },
  { key: 'interview1', label: 'Interview 1 (HR)', owner: 'Recruiter', target: 'interview_hr', optional: 'interview_hr',
    holds: (a) => a.in_play && a.sub_status_key === 'interview_hr' },
  { key: 'interview2', label: 'Interview 2 (Team)', owner: 'Panel', target: 'interview_to_schedule', optional: null,
    holds: (a) => a.in_play && a.stage_key === 'interview' && !OPTIONAL_INTERVIEW.has(a.sub_status_key ?? '') },
  { key: 'final', label: 'Final interview', owner: 'Director / CEO', target: 'interview_stakeholders', optional: 'interview_stakeholders',
    holds: (a) => a.in_play && a.sub_status_key === 'interview_stakeholders' },
  { key: 'offer', label: 'Offer', owner: 'HR', target: 'offer_made', optional: null,
    holds: (a) => a.in_play && a.stage_key === 'offer' },
  { key: 'hired', label: 'Hired', owner: 'HR', target: null, optional: null,
    holds: (a) => a.stage_key === 'hired' },
]

/** The columns this job uses: the optional ones it skips are left out. */
export function columnsFor(skip: readonly string[]): BoardColumn[] {
  return BOARD_COLUMNS.filter((c) => !c.optional || !skip.includes(c.optional))
}

/** Applications by column key; closed ones (rejected, withdrawn, closed with the job) are counted apart. */
export function arrange<T extends BoardApplication>(apps: readonly T[], skip: readonly string[]): { columns: Record<string, T[]>; closed: number } {
  const cols = columnsFor(skip)
  const columns: Record<string, T[]> = Object.fromEntries(cols.map((c) => [c.key, [] as T[]]))
  let closed = 0
  for (const a of apps) {
    const col = cols.find((c) => c.holds(a))
    if (col) columns[col.key] = [...columns[col.key], a]
    else closed += 1
  }
  return { columns, closed }
}

/** The status a card gets when dropped on a column, or null when it cannot go there. */
export function dropTarget(column: BoardColumn, card: BoardApplication): string | null {
  if (!column.target || !card.in_play || card.stage_key === 'hired') return null
  if (column.holds(card)) return null
  return column.target
}
