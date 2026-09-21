<script setup lang="ts">
import { onBeforeUnmount, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useDialogStore } from '@/stores/dialogs'
import { todayDb } from '@/lib/compensation'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import { SOURCE_FALLBACK_LABEL, contactBadge, contactState, longDate, type PoolRow } from '@/lib/candidatePool'

/**
 * Source from the talent pool — job → candidates (plan 052). A search over
 * search_candidates (pool holders only; the RPC refuses everyone else with
 * its own sentence), one "Add to this job" per row through
 * add_candidate_to_job, the dialog staying open so several can be added.
 * The contact rule is judged by the database; this only asks before
 * overriding a wait, and never offers the button to a flagged or archived
 * record.
 */
const props = defineProps<{ jobId: string; companyId: string; jobTitle: string; inPipeline: string[] }>()
const emit = defineEmits<{ created: [] }>()

const MIN_QUERY = 2
const DEBOUNCE_MS = 250
const PICK_LIMIT = 20
const PICK_SOURCE = 'head_hunt'

const dialogs = useDialogStore()
const dialog = ref<HTMLDialogElement | null>(null)
const q = ref('')
const rows = ref<PoolRow[]>([])
const searched = ref(false)
const loading = ref(false)
const error = ref<string | null>(null)
const addedIds = ref<string[]>([])
const busyId = ref<string | null>(null)
const today = todayDb()
let timer: ReturnType<typeof setTimeout> | null = null
let searchSeq = 0

function open(): void {
  q.value = ''
  rows.value = []
  searched.value = false
  error.value = null
  addedIds.value = []
  busyId.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

/** Native `close` (the button or Escape) tells the page to reload its rows. */
function onClose(): void {
  emit('created')
}

function onInput(): void {
  if (timer) clearTimeout(timer)
  timer = setTimeout(() => void search(), DEBOUNCE_MS)
}

onBeforeUnmount(() => {
  if (timer) clearTimeout(timer)
})

async function search(): Promise<void> {
  const seq = (searchSeq += 1)
  const term = q.value.trim()
  if (term.length < MIN_QUERY) {
    rows.value = []
    searched.value = false
    loading.value = false
    return
  }
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase.rpc('search_candidates', { p: { q: term, limit: PICK_LIMIT } })
  if (seq !== searchSeq) return
  loading.value = false
  searched.value = true
  if (err) {
    error.value = friendlyRecruitmentError(err.message)
    rows.value = []
    return
  }
  rows.value = ((data as { rows: PoolRow[] } | null)?.rows ?? []) as PoolRow[]
}

function isAdded(c: PoolRow): boolean {
  return addedIds.value.includes(c.id)
}

function inPipeline(c: PoolRow): boolean {
  return props.inPipeline.includes(c.id)
}

function canPick(c: PoolRow): boolean {
  return !c.do_not_contact && !c.archived_at
}

function mustWait(c: PoolRow): boolean {
  return contactState(c, today) === 'wait' && Boolean(c.contact_again_after)
}

function badgeClass(c: PoolRow): string {
  return contactState(c, today) === 'do_not_contact' ? 'amber' : 'blue'
}

function workLine(c: PoolRow): string {
  return [c.current_title, c.current_employer].filter(Boolean).join(' @ ')
}

async function pick(c: PoolRow): Promise<void> {
  error.value = null
  let override = false
  if (mustWait(c) && c.contact_again_after) {
    override = await dialogs.confirmAction({
      eyebrow: 'Talent pool',
      title: `${c.full_name} asked not to be contacted before ${longDate(c.contact_again_after)}.`,
      hint: `Add them to ${props.jobTitle} anyway?`,
      confirmLabel: 'Add anyway',
    })
    if (!override) return
  }
  busyId.value = c.id
  const { error: err } = await supabase.rpc('add_candidate_to_job', {
    p_candidate_id: c.id,
    p_job_id: props.jobId,
    p_source_key: PICK_SOURCE,
    p_override_wait: override,
  })
  busyId.value = null
  if (err) {
    error.value = friendlyRecruitmentError(err.message)
    return
  }
  addedIds.value = [...addedIds.value, c.id]
}
</script>

<template>
  <dialog ref="dialog" class="pick-from-pool" aria-labelledby="pick-from-pool-title" data-testid="pick-from-pool" @close="onClose">
    <div class="body">
      <div class="eyebrow">Talent pool</div>
      <h2 id="pick-from-pool-title">Source from the talent pool.</h2>
      <div class="field">
        <label for="pool-pick-search">Search</label>
        <input
          id="pool-pick-search"
          v-model="q"
          type="search"
          data-testid="pool-search"
          placeholder="Name, email, phone, LinkedIn, title, skill"
          autocomplete="off"
          @input="onInput"
        />
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div v-if="loading" class="empty">Searching…</div>
      <div v-else-if="!searched" class="empty">Type a name, email, LinkedIn address, title or skill.</div>
      <div v-else-if="!rows.length" class="empty">Nobody in the pool matches.</div>
      <ul v-else class="list">
        <li v-for="c in rows" :key="c.id" class="pick-row" :data-testid="`pool-pick-row-${c.id}`">
          <div class="text">
            <b>{{ c.full_name }}</b>
            <small class="sub">
              <template v-if="workLine(c)">{{ workLine(c) }} · </template>{{ c.source_label ?? SOURCE_FALLBACK_LABEL }}
            </small>
          </div>
          <div class="badges">
            <span v-if="contactBadge(c, today)" class="badge" :class="badgeClass(c)">{{ contactBadge(c, today) }}</span>
            <span v-if="c.archived_at" class="badge">Archived</span>
            <span v-if="inPipeline(c) && !isAdded(c)" class="badge">In pipeline</span>
            <span v-if="isAdded(c)" class="badge green">Added</span>
          </div>
          <button
            v-if="canPick(c) && !isAdded(c)"
            class="button secondary small-btn"
            type="button"
            :data-testid="`pool-pick-${c.id}`"
            :disabled="inPipeline(c) || busyId === c.id"
            @click="pick(c)"
          >
            {{ busyId === c.id ? 'Adding…' : 'Add to this job' }}
          </button>
        </li>
      </ul>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Close</button>
      </div>
    </div>
  </dialog>
</template>

<style scoped>
.pick-from-pool { border: 0; border-radius: 15px; padding: 0; width: min(640px, calc(100vw - 36px)); box-shadow: 0 25px 100px #122f3038; color: var(--ink); }
.pick-from-pool::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 14px; }
.list { list-style: none; margin: 0; padding: 0; max-height: min(50vh, 420px); overflow: auto; border-top: 1px solid var(--line); }
.pick-row { display: flex; align-items: center; gap: 12px; padding: 12px 4px; border-bottom: 1px solid var(--line); font-size: 12px; flex-wrap: wrap; }
.text { flex: 1; min-width: 200px; }
.text b { display: block; font-weight: 550; }
.sub { display: block; color: var(--muted); font-size: 11px; margin-top: 3px; }
.badges { display: flex; gap: 6px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.empty { padding: 28px 12px; }
.actions { display: flex; justify-content: flex-end; margin-top: 16px; }
</style>
