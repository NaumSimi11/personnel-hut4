/**
 * Removing a hiring status (plan 069, migration 0089): the words of the
 * Labels page's Remove dialog. `sub_status_usage` says how many applications
 * carry the status and how many timeline entries mention it;
 * `remove_sub_status` moves the applications (or leaves them), then deletes
 * a status nothing ever used and retires the rest. Pure phrasing — the
 * database decides.
 */

export type StatusUsage = { applications: number; history: number }
export type RemovalResult = { moved: number; outcome: 'deleted' | 'retired' }
export type RemovalPlan = { mode: 'delete' | 'retire' | 'move'; summary: string; confirmLabel: string }

const count = new Intl.NumberFormat('en-GB')

function applicationsWord(n: number): string {
  return `${count.format(n)} ${n === 1 ? 'application' : 'applications'}`
}

export function removalPlan(usage: StatusUsage, label: string): RemovalPlan {
  if (usage.applications > 0) {
    return { mode: 'move', summary: `“${label}” is on ${applicationsWord(usage.applications)}.`, confirmLabel: 'Remove status' }
  }
  if (usage.history > 0) {
    const entries = usage.history === 1 ? '1 timeline entry mentions it' : `${count.format(usage.history)} timeline entries mention it`
    return {
      mode: 'retire',
      summary: `No application has “${label}” now, but ${entries}, so it will be retired and they will still read.`,
      confirmLabel: 'Remove status',
    }
  }
  return { mode: 'delete', summary: `Nobody has used “${label}”. It will be deleted.`, confirmLabel: 'Delete status' }
}

export function removalNotice(result: RemovalResult, label: string, movedTo: string | null): string {
  if (result.outcome === 'deleted') return `Deleted “${label}”.`
  if (result.moved > 0 && movedTo) {
    return `Moved ${applicationsWord(result.moved)} from “${label}” to “${movedTo}”, and retired “${label}”.`
  }
  return `Retired “${label}”. Applications that have it keep it; nobody can pick it any more.`
}
