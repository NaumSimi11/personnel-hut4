/**
 * One thing's past, in the order it happened.
 *
 * An asset's history was scattered across three tables that each answered a
 * different question — who held it, how it came back, which company owns it —
 * and a service note had nowhere to live at all. Somebody asking "what is this
 * and what has happened to it" had to read all of them and hold the dates in
 * their head.
 *
 * Reservations that never became an issue are left out: reserved and then
 * cancelled is not something that happened to the thing, it is something that
 * nearly did.
 */
export type HistoryKind = 'issued' | 'returned' | 'transferred' | 'service' | 'damage' | 'condition' | 'note' | 'registered'

export type HistoryRow = {
  readonly on: string
  readonly kind: HistoryKind
  readonly text: string
}

export type HistoryInput = {
  readonly createdAt: string
  readonly assignments: readonly {
    readonly issued_at: string | null
    readonly returned_at: string | null
    readonly person: string
    readonly return_condition: string | null
  }[]
  readonly notes: readonly {
    readonly happened_on: string
    readonly kind: string
    readonly body: string
    readonly about: string | null
  }[]
  readonly transfers: readonly {
    readonly transferred_at: string
    readonly from: string | null
    readonly to: string | null
    readonly by: string
  }[]
}

const day = (iso: string) => iso.slice(0, 10)

export function assetHistory(input: HistoryInput): HistoryRow[] {
  const rows: HistoryRow[] = []

  for (const a of input.assignments) {
    if (a.issued_at) rows.push({ on: day(a.issued_at), kind: 'issued', text: `Issued to ${a.person}` })
    if (a.returned_at) {
      rows.push({
        on: day(a.returned_at),
        kind: 'returned',
        text: a.return_condition ? `Returned by ${a.person} · ${a.return_condition}` : `Returned by ${a.person}`,
      })
    }
  }

  for (const t of input.transfers) {
    rows.push({
      on: day(t.transferred_at),
      kind: 'transferred',
      text: `Moved from ${t.from ?? 'the holding'} to ${t.to ?? 'the holding'} by ${t.by}`,
    })
  }

  for (const n of input.notes) {
    rows.push({
      on: n.happened_on,
      kind: (n.kind as HistoryKind) ?? 'note',
      text: n.about ? `${n.body} · while ${n.about} had it` : n.body,
    })
  }

  rows.push({ on: day(input.createdAt), kind: 'registered', text: 'Registered' })
  // Newest first, and the registration stays last however the dates fall.
  return rows.sort((a, b) => (a.on === b.on ? 0 : a.on < b.on ? 1 : -1))
}
