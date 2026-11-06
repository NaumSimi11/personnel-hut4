import { ref } from 'vue'
import { defineStore } from 'pinia'
import { supabase } from '@/lib/supabase'

/**
 * My notifications (plan 043): what happened that concerns me — read from
 * the rows the database created (RLS: my own only). The bell shows the
 * unread count, a head-only count taken every minute while the tab is
 * visible (egress: no rows travel); the 100-row list loads only when the
 * Notifications page opens; the page lists them; reading, archiving, restoring and
 * deleting (plan 071) are function calls so the table stays read-only from
 * the client. The bell and the page's first two lists leave archived ones out.
 */
export type NotificationRow = {
  id: string
  kind: string
  title: string
  body: string | null
  link: string | null
  read_at: string | null
  archived_at?: string | null
  created_at: string
  email_status: string
  email_to: string | null
}

const POLL_MS = 60_000

export const useNotificationsStore = defineStore('notifications', () => {
  const items = ref<NotificationRow[]>([])
  const loaded = ref(false)
  const unread = ref(0)
  let timer: ReturnType<typeof setInterval> | null = null
  // Bumped by stop(): a count that resolves after sign-out must not repaint the bell.
  let session = 0

  const tabVisible = () => document.visibilityState === 'visible'

  /** How many unread, unarchived notifications are mine: a count only, no rows. */
  async function refreshUnread(): Promise<void> {
    const mine = session
    const { count, error } = await supabase
      .from('notifications')
      .select('id', { count: 'exact', head: true })
      .is('read_at', null)
      .is('archived_at', null)
    if (mine !== session) return
    if (error) {
      console.error('Unread count failed:', error.message)
      return
    }
    unread.value = count ?? 0
  }

  async function load(): Promise<void> {
    const { data, error } = await supabase
      .from('notifications')
      .select('id, kind, title, body, link, read_at, created_at, email_status, email_to')
      .is('archived_at', null)
      .order('created_at', { ascending: false })
      .limit(100)
    if (error) {
      console.error('Notifications load failed:', error.message)
      return
    }
    items.value = (data ?? []) as NotificationRow[]
    loaded.value = true
    void refreshUnread()
  }

  async function markRead(ids?: string[]): Promise<void> {
    const { error } = await supabase.rpc('mark_notifications_read', ids ? { p_ids: ids } : {})
    if (error) {
      console.error('Marking notifications read failed:', error.message)
      return
    }
    const at = new Date().toISOString()
    items.value = items.value.map((n) => (!ids || ids.includes(n.id) ? { ...n, read_at: n.read_at ?? at } : n))
    void refreshUnread()
  }

  /** Archive picked ones of mine, or (no ids) every read one; then reload. Returns how many. */
  async function archive(ids?: string[]): Promise<number> {
    const { data, error } = await supabase.rpc('archive_notifications', ids ? { p_ids: ids } : {})
    if (error) throw new Error(error.message)
    await load()
    return (data as number | null) ?? 0
  }

  async function restore(ids: string[]): Promise<number> {
    const { data, error } = await supabase.rpc('restore_notifications', { p_ids: ids })
    if (error) throw new Error(error.message)
    await load()
    return (data as number | null) ?? 0
  }

  /** Delete picked ones of mine, or every read ('read') or archived ('archived') one. */
  async function remove(target: { ids: string[] } | { where: 'read' | 'archived' }): Promise<number> {
    const args = 'ids' in target ? { p_ids: target.ids } : { p_where: target.where }
    const { data, error } = await supabase.rpc('delete_notifications', args)
    if (error) throw new Error(error.message)
    await load()
    return (data as number | null) ?? 0
  }

  function onVisibilityChange(): void {
    if (tabVisible()) void refreshUnread()
  }

  /** Count now and every POLL_MS, but only while the tab is on screen. */
  function start(): void {
    if (timer) return
    if (tabVisible()) void refreshUnread()
    timer = setInterval(() => {
      if (tabVisible()) void refreshUnread()
    }, POLL_MS)
    document.addEventListener('visibilitychange', onVisibilityChange)
  }
  function stop(): void {
    session += 1
    if (timer) clearInterval(timer)
    timer = null
    document.removeEventListener('visibilitychange', onVisibilityChange)
    items.value = []
    unread.value = 0
    loaded.value = false
  }

  return { items, unread, loaded, load, refreshUnread, markRead, archive, restore, remove, start, stop }
})
