/**
 * The approval route of a request or offer as steps (0104; spec 1.4): the
 * latest round, one line per position, the newest row winning where a step
 * was reopened after changes were asked.
 */
export type TrailRow = {
  subject_id: string
  round: number
  position: number
  label: string
  status: 'open' | 'approved' | 'changes_requested' | 'rejected' | 'superseded'
  comment: string | null
  acted_at: string | null
  approver: { full_name: string } | null
  actor: { full_name: string } | null
}
export type TrailStep = {
  position: number
  label: string
  state: 'done' | 'waiting' | 'next' | 'returned' | 'stopped'
  who: string | null
  comment: string | null
}

export function latestRoundSteps(rows: readonly TrailRow[]): Record<string, TrailStep[]> {
  const bySubject = new Map<string, TrailRow[]>()
  for (const r of rows) bySubject.set(r.subject_id, [...(bySubject.get(r.subject_id) ?? []), r])
  const out: Record<string, TrailStep[]> = {}
  for (const [id, list] of bySubject) {
    const round = Math.max(...list.map((r) => r.round))
    const byPosition = new Map<number, TrailRow>()
    for (const r of list.filter((x) => x.round === round)) {
      const seen = byPosition.get(r.position)
      // An open row (a step reopened after changes) wins over the decided one it replaced.
      if (!seen || r.status === 'open' || (seen.status !== 'open' && (r.acted_at ?? '') > (seen.acted_at ?? ''))) byPosition.set(r.position, r)
    }
    const ordered = [...byPosition.values()].sort((a, b) => a.position - b.position)
    const firstOpen = ordered.find((r) => r.status === 'open')?.position
    out[id] = ordered.map((r) => ({
      position: r.position,
      label: r.label,
      state:
        r.status === 'approved' ? 'done'
        : r.status === 'open' ? (r.position === firstOpen ? 'waiting' : 'next')
        : r.status === 'changes_requested' ? 'returned'
        : 'stopped',
      who: r.status === 'open' ? (r.approver?.full_name ?? null) : (r.actor?.full_name ?? null),
      comment: r.comment,
    }))
  }
  return out
}

export function stepLine(s: TrailStep): string {
  const who = s.who ? ` · ${s.who}` : ''
  const note = s.comment && s.state !== 'done' ? ` — “${s.comment}”` : ''
  const verb = { done: 'approved', waiting: 'waiting', next: 'next', returned: 'asked for changes', stopped: 'stopped' }[s.state]
  return `${s.position}. ${s.label}: ${verb}${who}${note}`
}
