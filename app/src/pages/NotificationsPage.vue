<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useDialogStore } from '@/stores/dialogs'
import { useNotificationsStore, type NotificationRow } from '@/stores/notifications'
import { deleteConfirm, tidyNotice, toggleAll, toggleOne, type DeleteHeap } from '@/lib/notificationTidy'

/**
 * Everything that happened that concerns me (plan 043): leave decided,
 * requests to approve, a candidate handed to me, a document asked of me…
 * Each row opens where the thing is; opening marks it read. The email
 * column says whether a mail went too — the same fact HR sees on the row.
 * Since plan 071 the read ones can be archived (out of sight, kept) and
 * deleted for good: picked ones, or every read or archived one at once —
 * the totals are counted on the server, past the hundred shown.
 */
const ARCHIVED_SHOWN = 100

const store = useNotificationsStore()
const dialogs = useDialogStore()
const router = useRouter()

const unread = computed(() => store.items.filter((n) => !n.read_at))
const earlier = computed(() => store.items.filter((n) => n.read_at))

const view = ref<'earlier' | 'archived'>('earlier')
const archivedItems = ref<NotificationRow[]>([])
const readTotal = ref(0)
const archivedTotal = ref(0)
const selected = ref<string[]>([])
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const shown = computed(() => (view.value === 'earlier' ? earlier.value : archivedItems.value))
const shownIds = computed(() => shown.value.map((n) => n.id))
const allPicked = computed(() => shownIds.value.length > 0 && shownIds.value.every((id) => selected.value.includes(id)))
const heapTotal = computed(() => (view.value === 'earlier' ? readTotal.value : archivedTotal.value))

async function loadCounts(): Promise<void> {
  const mine = () => supabase.from('notifications').select('id', { count: 'exact', head: true })
  const [read, archived] = await Promise.all([
    mine().is('archived_at', null).not('read_at', 'is', null),
    mine().not('archived_at', 'is', null),
  ])
  if (read.error || archived.error) {
    console.error('Notification counts failed:', read.error?.message ?? archived.error?.message)
    return
  }
  readTotal.value = read.count ?? 0
  archivedTotal.value = archived.count ?? 0
}

async function loadArchived(): Promise<void> {
  const { data, error: err } = await supabase
    .from('notifications')
    .select('id, kind, title, body, link, read_at, archived_at, created_at, email_status, email_to')
    .not('archived_at', 'is', null)
    .order('archived_at', { ascending: false })
    .limit(ARCHIVED_SHOWN)
  if (err) {
    error.value = 'Could not load the archived notifications.'
    console.error('Archived notifications load failed:', err.message)
    return
  }
  archivedItems.value = (data ?? []) as NotificationRow[]
}

async function refresh(): Promise<void> {
  await Promise.all([store.load(), loadCounts(), view.value === 'archived' ? loadArchived() : Promise.resolve()])
}

function setView(next: 'earlier' | 'archived'): void {
  view.value = next
  selected.value = []
  notice.value = null
  error.value = null
  if (next === 'archived') void loadArchived()
}

/** Run one tidy call, then say what happened and refresh every list and count. */
async function run(action: () => Promise<number>, done: 'archived' | 'restored' | 'deleted'): Promise<void> {
  busy.value = true
  error.value = null
  notice.value = null
  try {
    const n = await action()
    selected.value = []
    notice.value = tidyNotice(done, n)
    await refresh()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not tidy the notifications.'
  } finally {
    busy.value = false
  }
}

async function confirmDelete(n: number, heap: DeleteHeap): Promise<boolean> {
  const words = deleteConfirm(n, heap)
  return dialogs.confirmAction({ ...words, confirmLabel: 'Delete for good', danger: true })
}

function archivePicked(): void {
  void run(() => store.archive([...selected.value]), 'archived')
}
function archiveAllRead(): void {
  void run(() => store.archive(), 'archived')
}
function restorePicked(): void {
  void run(() => store.restore([...selected.value]), 'restored')
}
async function deletePicked(): Promise<void> {
  const ids = [...selected.value]
  if (!(await confirmDelete(ids.length, 'picked'))) return
  void run(() => store.remove({ ids }), 'deleted')
}
async function deleteAll(): Promise<void> {
  const heap = view.value === 'earlier' ? 'read' : 'archived'
  if (!(await confirmDelete(heapTotal.value, heap))) return
  void run(() => store.remove({ where: heap }), 'deleted')
}

function when(iso: string): string {
  const d = new Date(iso)
  const now = Date.now()
  const min = Math.round((now - d.getTime()) / 60_000)
  if (min < 1) return 'just now'
  if (min < 60) return `${min} min ago`
  if (min < 60 * 24) return `${Math.round(min / 60)} h ago`
  return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })
}
function emailLabel(n: NotificationRow): string {
  switch (n.email_status) {
    case 'sent':
      return `emailed to ${n.email_to}`
    case 'pending':
      return 'email queued'
    case 'failed':
      return 'email failed'
    default:
      return 'in-app only'
  }
}
async function open(n: NotificationRow): Promise<void> {
  if (!n.read_at) await store.markRead([n.id])
  if (n.link) void router.push(n.link)
}

onMounted(() => void refresh())
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">Notifications</div>
        <h1>What happened, for you.</h1>
        <p class="page-sub">Decisions on your requests, things waiting on you, and what colleagues handed over.</p>
      </div>
      <button v-if="unread.length" class="button secondary" type="button" @click="store.markRead()">Mark all read</button>
    </div>

    <div class="card">
      <div class="card-head">
        <div>
          <h2>Unread <span class="count">{{ unread.length }}</span></h2>
          <p>Opening one marks it read.</p>
        </div>
      </div>
      <div v-if="!store.loaded" class="empty">Loading…</div>
      <div v-else-if="!unread.length" class="empty">Nothing new. You are up to date.</div>
      <ul v-else class="list">
        <li v-for="n in unread" :key="n.id" class="row unread" :data-testid="`notification-${n.id}`">
          <button class="open" type="button" @click="open(n)">
            <b>{{ n.title }}</b>
            <small v-if="n.body">{{ n.body }}</small>
            <small class="meta">{{ when(n.created_at) }} · {{ emailLabel(n) }}</small>
          </button>
        </li>
      </ul>
    </div>

    <div class="card section" data-testid="notifications-tidy">
      <div class="card-head">
        <div>
          <div class="views" role="tablist" aria-label="Read notifications">
            <button
              class="view"
              :class="{ active: view === 'earlier' }"
              type="button"
              role="tab"
              :aria-selected="view === 'earlier'"
              data-testid="notifications-view-earlier"
              @click="setView('earlier')"
            >
              Earlier ({{ readTotal.toLocaleString('en-GB') }})
            </button>
            <button
              class="view"
              :class="{ active: view === 'archived' }"
              type="button"
              role="tab"
              :aria-selected="view === 'archived'"
              data-testid="notifications-view-archived"
              @click="setView('archived')"
            >
              Archived ({{ archivedTotal.toLocaleString('en-GB') }})
            </button>
          </div>
          <p>{{ view === 'earlier' ? 'Read notifications, newest first.' : 'Out of sight and kept, until you delete them.' }}</p>
        </div>
      </div>
      <div v-if="shown.length" class="toolbar">
        <label class="check">
          <input type="checkbox" :checked="allPicked" :disabled="busy" data-testid="notifications-select-all" @change="selected = toggleAll(selected, shownIds)" />
          <span>Select all</span>
        </label>
        <template v-if="selected.length">
          <button v-if="view === 'earlier'" class="button secondary small-btn" type="button" :disabled="busy" data-testid="notifications-archive" @click="archivePicked">
            Archive ({{ selected.length }})
          </button>
          <button v-else class="button secondary small-btn" type="button" :disabled="busy" data-testid="notifications-restore" @click="restorePicked">
            Restore ({{ selected.length }})
          </button>
          <button class="button secondary small-btn danger-text" type="button" :disabled="busy" data-testid="notifications-delete" @click="deletePicked">
            Delete ({{ selected.length }})
          </button>
        </template>
        <template v-else>
          <button v-if="view === 'earlier'" class="button secondary small-btn" type="button" :disabled="busy" data-testid="notifications-archive-all" @click="archiveAllRead">
            Archive all read ({{ readTotal.toLocaleString('en-GB') }})
          </button>
          <button class="button secondary small-btn danger-text" type="button" :disabled="busy" data-testid="notifications-delete-all" @click="deleteAll">
            Delete all {{ view === 'earlier' ? 'read' : 'archived' }} ({{ heapTotal.toLocaleString('en-GB') }})
          </button>
        </template>
      </div>
      <output v-if="notice" class="notice" data-testid="notifications-notice">{{ notice }}</output>
      <p v-if="error" class="error-note" role="alert" style="margin: 0 24px 12px">{{ error }}</p>
      <div v-if="!shown.length" class="empty">{{ view === 'earlier' ? 'No read notifications.' : 'Nothing archived.' }}</div>
      <ul v-else class="list">
        <li v-for="n in shown" :key="n.id" class="row pickable" :data-testid="`notification-${n.id}`">
          <input
            class="pick"
            type="checkbox"
            :checked="selected.includes(n.id)"
            :disabled="busy"
            :aria-label="`Select ${n.title}`"
            @change="selected = toggleOne(selected, n.id, ($event.target as HTMLInputElement).checked)"
          />
          <button class="open" type="button" @click="open(n)">
            <b>{{ n.title }}</b>
            <small v-if="n.body">{{ n.body }}</small>
            <small class="meta">{{ when(n.created_at) }} · {{ emailLabel(n) }}</small>
          </button>
        </li>
      </ul>
      <p v-if="shown.length < heapTotal" class="more-note">
        Showing the latest {{ shown.length.toLocaleString('en-GB') }} of {{ heapTotal.toLocaleString('en-GB') }}. The
        "all" buttons take every one of them.
      </p>
    </div>
  </div>
</template>

<style scoped>
.page-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 22px; }
.page-sub { margin: 0; font-size: 13px; color: var(--muted); }
.count { display: inline-grid; place-items: center; min-width: 22px; height: 22px; padding: 0 7px; border-radius: 999px; background: var(--green); color: #fff; font-size: 11px; margin-left: 6px; vertical-align: middle; }
.section { margin-top: 22px; }
summary { cursor: pointer; list-style: none; }
summary::-webkit-details-marker { display: none; }
.list { list-style: none; margin: 0; padding: 0; }
.row { border-top: 1px solid var(--line); }
.open { display: grid; gap: 3px; width: 100%; text-align: left; background: none; border: 0; padding: 14px 24px; color: var(--ink); border-radius: 0; }
.open:hover { background: #f7f9f5; }
.row.unread .open { border-left: 3px solid var(--green-bright); padding-left: 21px; }
.open b { font-size: 13px; font-weight: 600; }
.open small { font-size: 12px; color: var(--ink); }
.open .meta { font-size: 11px; color: var(--muted); }
.views { display: flex; gap: 6px; margin-bottom: 6px; }
.view { background: none; border: 0; border-bottom: 2px solid transparent; padding: 4px 2px; margin-right: 12px; font-size: 16px; font-weight: 600; color: var(--muted); border-radius: 0; }
.view.active { color: var(--ink); border-bottom-color: var(--green); }
.toolbar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; padding: 0 24px 14px; }
.check { display: inline-flex; align-items: center; gap: 7px; font-size: 12px; margin-right: 8px; cursor: pointer; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.notice { display: block; margin: 0 24px 12px; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.row.pickable { display: flex; align-items: center; }
.pick { margin-left: 24px; flex: none; }
.row.pickable .open { padding-left: 14px; }
.more-note { margin: 0; padding: 12px 24px; font-size: 11px; color: var(--muted); border-top: 1px solid var(--line); }
</style>
