/** Guidance is navigational; existing permissions and transitions remain authoritative. */
export function candidateNextStep(stage: string): { title: string; target: string; label: string } {
  switch (stage) {
    case 'new':
    case 'screening': return { title: 'Review the CV and responses, then decide whether to interview.', target: 'candidate-review', label: 'Review candidate' }
    case 'interview': return { title: 'Schedule interviews and collect feedback before agreeing an offer.', target: 'candidate-interviews', label: 'Review interviews' }
    case 'offer': return { title: 'Review the offer and agreed terms. Confirm the hire after acceptance.', target: 'candidate-offer', label: 'Review offer' }
    case 'hired': return { title: 'Continue to the employee record and onboarding preparations.', target: 'candidate-decision', label: 'View handoff' }
    default: return { title: 'This application is closed. Its history remains available below.', target: 'candidate-decision', label: 'View decision' }
  }
}

export type CandidateAction = {
  stage_key: string
  next_action_due: string | null
  owner: { full_name: string } | null
}

export function isActiveCandidate(row: CandidateAction): boolean {
  return !['hired', 'rejected', 'withdrawn'].includes(row.stage_key)
}

/** Due work first, then missing owners; terminal applications never enter the queue. */
export function candidateQueue<T extends CandidateAction>(rows: T[]): T[] {
  return rows.filter(isActiveCandidate).sort((a, b) =>
    (a.next_action_due ?? '9999-12-31').localeCompare(b.next_action_due ?? '9999-12-31') ||
    Number(Boolean(a.owner)) - Number(Boolean(b.owner)),
  )
}
