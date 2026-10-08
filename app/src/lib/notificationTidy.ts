/**
 * Tidying my notifications (plan 071, migration 0091): the selection rules
 * and the words of the Notifications page's archive / restore / delete.
 * Pure — archive_notifications, restore_notifications and
 * delete_notifications do the work, on my own rows only.
 */

export type DeleteHeap = 'picked' | 'read' | 'archived'
export type TidyAction = 'archived' | 'restored' | 'deleted'

const count = new Intl.NumberFormat('en-GB')

function notifications(n: number): string {
  return `${count.format(n)} ${n === 1 ? 'notification' : 'notifications'}`
}

/** "Select all": every shown row, or none when they are all picked already. */
export function toggleAll(selected: ReadonlyArray<string>, shown: ReadonlyArray<string>): string[] {
  const all = shown.length > 0 && shown.every((id) => selected.includes(id))
  return all ? [] : [...shown]
}

export function toggleOne(selected: ReadonlyArray<string>, id: string, checked: boolean): string[] {
  return checked ? [...new Set([...selected, id])] : selected.filter((x) => x !== id)
}

export function deleteConfirm(n: number, heap: DeleteHeap): { title: string; hint: string } {
  const gone = 'They are gone for good — this cannot be undone.'
  if (heap === 'picked') return { title: `Delete ${notifications(n)}?`, hint: `${gone} Archive them instead to keep them out of sight.` }
  const which = heap === 'read' ? 'read' : 'archived'
  const title = n === 1 ? `Delete your 1 ${which} notification?` : `Delete all ${count.format(n)} ${which} notifications?`
  return { title, hint: heap === 'read' ? `${gone} Unread ones stay.` : gone }
}

export function tidyNotice(action: TidyAction, n: number): string {
  if (n === 0) return `Nothing to ${action === 'archived' ? 'archive' : action === 'restored' ? 'restore' : 'delete'}.`
  const done = `${action[0].toUpperCase()}${action.slice(1)} ${notifications(n)}.`
  return action === 'archived' ? `${done} They are under Archived.` : done
}
