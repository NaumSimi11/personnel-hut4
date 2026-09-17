/**
 * Where a day, and a leave, stand relative to today.
 *
 * The calendar answers questions about the day you clicked, which is right for
 * "who was away on the 10th" and wrong for the wording around it. A past
 * Thursday labelled "Working day · A normal day" reads as though the app is
 * describing the calendar rather than telling you what happened, and a leave
 * shown as "working day 8 of 9 · 1 left" reads as though it is still running
 * when it finished a week ago. Both are true of the selected day and both
 * mislead the person looking today.
 */
export type DayStanding = 'past' | 'today' | 'future'
export type DayKind = 'working' | 'weekend' | 'holiday' | 'closure'

export function dayStanding(iso: string, today: string): DayStanding {
  if (iso < today) return 'past'
  if (iso > today) return 'future'
  return 'today'
}

const KIND_WORDS: Record<DayKind, { noun: string; sub: string }> = {
  working: { noun: 'working day', sub: 'A normal day' },
  weekend: { noun: 'weekend', sub: 'Not a working day' },
  holiday: { noun: 'public holiday', sub: 'Does not count as leave' },
  closure: { noun: 'company closure', sub: 'Does not count as leave' },
}

function sentenceCase(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1)
}

export function dayHeadline(kind: DayKind, standing: DayStanding): { title: string; sub: string } {
  const words = KIND_WORDS[kind]
  if (standing === 'past') return { title: `Was a ${words.noun}`, sub: words.sub }
  if (standing === 'future') {
    // "A working day" rather than "Will be a working day", which reads as a
    // forecast about something already in the calendar.
    return { title: kind === 'working' ? 'A working day' : sentenceCase(words.noun), sub: words.sub }
  }
  return { title: sentenceCase(words.noun), sub: words.sub }
}

export type LeaveStanding = 'finished' | 'running' | 'upcoming'

/** Where a leave stands TODAY, whatever day of it you happen to be looking at. */
export function leaveStanding(leave: { start: string; end: string | null }, today: string): LeaveStanding {
  if (leave.start > today) return 'upcoming'
  if (leave.end !== null && leave.end < today) return 'finished'
  return 'running'
}
