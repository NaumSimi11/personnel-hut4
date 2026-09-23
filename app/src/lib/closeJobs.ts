/**
 * Closing job openings from the Job openings list (plan 056).
 *
 * The database does the work — `close_jobs(ids, reason, withdraw)` closes a
 * selection and, when asked, withdraws whoever is still in play on it. These
 * are the sentences around it: what a selection is about to do, what it did,
 * and what a refusal means in words a person can act on.
 */

export type CloseTarget = {
  id: string
  title: string
  /** The company's name, for a refusal that has to name it. */
  company: string
  /** `jobs.status` as stored. */
  status: string
  /** Applications on the job that are neither hired, rejected nor withdrawn. */
  inPlay: number
  /** Whether the viewer holds jobs.edit in the job's company. */
  mayEdit: boolean
  /** Whether they also hold candidates.review there — the price of withdrawing. */
  mayWithdraw: boolean
}

export type CloseSelection = {
  /** How many of the picked rows are not closed yet. */
  toClose: number
  /** How many are closed already — the call counts them and leaves them alone. */
  alreadyClosed: number
  /** Candidates still in play across the picked rows. */
  inPlay: number
  /** How many openings were picked. */
  jobs: number
  /**
   * Whether withdrawing may even be offered. `close_jobs` demands
   * candidates.review in *every* company of the call, not only the ones with
   * somebody in play, and refuses the whole call otherwise — so one company
   * the viewer cannot review in takes the option away rather than losing them
   * the close as well.
   */
  mayWithdraw: boolean
  /** The company that took it away, when one did. */
  withdrawBlockedBy: string | null
}

export type CloseOutcome = { closed: number; already_closed: number; withdrawn: number }

const plural = (n: number, one: string, many = `${one}s`): string => `${n} ${n === 1 ? one : many}`

/** What the picked rows amount to, for the dialog's heading and its checkbox. */
export function closeSelection(rows: ReadonlyArray<CloseTarget>): CloseSelection {
  const blocker = rows.find((r) => !r.mayWithdraw)
  return {
    jobs: rows.length,
    toClose: rows.filter((r) => r.status !== 'closed').length,
    alreadyClosed: rows.filter((r) => r.status === 'closed').length,
    inPlay: rows.reduce((sum, r) => sum + r.inPlay, 0),
    mayWithdraw: rows.length > 0 && !blocker,
    withdrawBlockedBy: blocker?.company ?? null,
  }
}

/** Why a row cannot be picked, or null when it can. */
export function whyNotSelectable(row: CloseTarget): string | null {
  if (!row.mayEdit) return 'You cannot edit jobs in this company.'
  return null
}

/**
 * The sentence the dialog asks the question with. It never hides the
 * consequence: if candidates will be withdrawn, it says how many before the
 * button is pressed.
 */
export function closeQuestion(selection: CloseSelection, withdraw: boolean): string {
  const jobs = plural(selection.toClose, 'opening')
  if (selection.toClose === 0) {
    const all = selection.alreadyClosed === 1 ? 'That opening is' : `All ${selection.alreadyClosed} are`
    // Closed already does not mean settled: the imported backlog is full of
    // closed openings with people still waiting on them, and withdrawing
    // those is the whole point of the sweep.
    if (selection.inPlay === 0) return `${all} already closed. Nothing will change.`
    if (!withdraw) {
      const on = selection.alreadyClosed === 1 ? 'on it' : 'on them'
      return `${all} already closed, but ${plural(selection.inPlay, 'candidate')} ${on} ${selection.inPlay === 1 ? 'is' : 'are'} still in play.`
    }
    return `${all} already closed. ${plural(selection.inPlay, 'candidate')} still in play will be withdrawn with the reason below.`
  }
  const already = selection.alreadyClosed
    ? ` ${plural(selection.alreadyClosed, 'other')} in the selection ${selection.alreadyClosed === 1 ? 'is' : 'are'} already closed and stays as it is.`
    : ''
  if (!withdraw || selection.inPlay === 0) {
    const waiting = selection.inPlay
      ? ` ${plural(selection.inPlay, 'candidate')} stay in play and keep counting until somebody answers them.`
      : ''
    return `${jobs} will close.${waiting}${already}`
  }
  return `${jobs} will close and ${plural(selection.inPlay, 'candidate')} still in play will be withdrawn with the reason below.${already}`
}

/** What happened, once it has. */
export function closeSummary(outcome: CloseOutcome): string {
  const parts: string[] = []
  parts.push(outcome.closed === 0 ? 'Nothing left to close' : `${plural(outcome.closed, 'opening')} closed`)
  if (outcome.already_closed) parts.push(`${plural(outcome.already_closed, 'was', 'were')} closed already`)
  if (outcome.withdrawn) parts.push(`${plural(outcome.withdrawn, 'candidate')} withdrawn`)
  return `${parts.join(' · ')}.`
}

/** The database's refusals, and the ones it cannot phrase for itself. */
export function friendlyCloseError(message: string): string {
  if (/row-level security/i.test(message)) return 'You cannot edit jobs in this company.'
  if (/jwt|not authenticated/i.test(message)) return 'Your session expired. Sign in again.'
  // close_jobs raises its own sentences (capability, unknown job, blank
  // reason); they are already written for a person to read.
  return message
}
