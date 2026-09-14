<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { useNotificationsStore, type NotificationRow } from '@/stores/notifications'

/**
 * Everything that happened that concerns me (plan 043): leave decided,
 * requests to approve, a candidate handed to me, a document asked of me…
 * Each row opens where the thing is; opening marks it read. The email
 * column says whether a mail went too — the same fact HR sees on the row.
 */
const store = useNotificationsStore()
const router = useRouter()

const unread = computed(() => store.items.filter((n) => !n.read_at))
const earlier = computed(() => store.items.filter((n) => n.read_at))

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

onMounted(() => void store.load())
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

    <details v-if="earlier.length" class="card section">
      <summary class="card-head">
        <div>
          <h2>Earlier ({{ earlier.length }})</h2>
          <p>Read notifications from the last hundred.</p>
        </div>
      </summary>
      <ul class="list">
        <li v-for="n in earlier" :key="n.id" class="row">
          <button class="open" type="button" @click="open(n)">
            <b>{{ n.title }}</b>
            <small v-if="n.body">{{ n.body }}</small>
            <small class="meta">{{ when(n.created_at) }} · {{ emailLabel(n) }}</small>
          </button>
        </li>
      </ul>
    </details>
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
</style>
