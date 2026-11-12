<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { deliverNotifications } from '@/lib/notificationsApi'

/**
 * After the last position is filled (0110; spec 7.5): every application the
 * fill closed waits here for the recruiter's choice — reject (the rejection
 * email goes), keep in the talent pool, or keep on hold in case the position
 * reopens. Nothing is sent until they choose.
 */
type Left = { id: string; stage_key: string; candidate: { full_name: string } | null; after_fill: string | null }

const props = defineProps<{ jobId: string; canReview: boolean }>()
const emit = defineEmits<{ changed: [] }>()
const rows = ref<Left[]>([])
const picked = ref<Set<string>>(new Set())
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

async function load(): Promise<void> {
  const { data, error: err } = await supabase
    .from('applications')
    .select('id, stage_key, after_fill, candidate:candidates(full_name)')
    .eq('job_id', props.jobId)
    .not('closed_at', 'is', null)
    .or('after_fill.is.null,after_fill.eq.hold')
    .order('received_at', { ascending: false })
    .limit(200)
  if (err) {
    console.error('After-fill load failed:', err.message)
    error.value = 'Could not load the remaining applications.'
    return
  }
  rows.value = (data ?? []) as unknown as Left[]
  picked.value = new Set()
}

function toggle(id: string): void {
  const next = new Set(picked.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  picked.value = next
}

async function decide(action: 'rejected' | 'pool' | 'hold'): Promise<void> {
  if (!picked.value.size) return
  busy.value = true
  error.value = null
  notice.value = null
  const { data, error: err } = await supabase.rpc('decide_after_fill', { p_application_ids: [...picked.value], p_action: action })
  busy.value = false
  if (err) {
    console.error('decide_after_fill failed:', err.message)
    error.value = err.message
    return
  }
  const r = (data ?? {}) as { decided?: number; emailed?: number }
  notice.value =
    action === 'rejected'
      ? `${r.decided ?? 0} rejected · ${r.emailed ?? 0} rejection email${r.emailed === 1 ? '' : 's'} queued.`
      : action === 'pool'
        ? `${r.decided ?? 0} kept in the talent pool.`
        : `${r.decided ?? 0} kept on hold — they come back into play if the position reopens.`
  if (action === 'rejected') void deliverNotifications()
  await load()
  emit('changed')
}

watch(() => props.jobId, load)
onMounted(load)
</script>

<template>
  <div v-if="rows.length" class="card after-fill" data-testid="after-fill">
    <div class="card-head">
      <div>
        <h2>After the hire</h2>
        <p>The position is filled. Decide what happens to the other applications — nothing is sent until you do.</p>
      </div>
    </div>
    <ul class="rows">
      <li v-for="r in rows" :key="r.id">
        <label>
          <input type="checkbox" :checked="picked.has(r.id)" :disabled="!canReview || busy" @change="toggle(r.id)" />
          {{ r.candidate?.full_name ?? '—' }}
        </label>
        <small>{{ r.stage_key }}<template v-if="r.after_fill === 'hold'"> · on hold</template></small>
      </li>
    </ul>
    <div v-if="canReview" class="actions">
      <button class="button secondary small-btn danger-text" type="button" :disabled="busy || !picked.size" @click="decide('rejected')">Reject and email</button>
      <button class="button secondary small-btn" type="button" :disabled="busy || !picked.size" @click="decide('pool')">Keep in the talent pool</button>
      <button class="button secondary small-btn" type="button" :disabled="busy || !picked.size" @click="decide('hold')">Keep on hold</button>
    </div>
    <p v-if="notice" class="notice" role="status">{{ notice }}</p>
    <p v-if="error" class="error" role="alert">{{ error }}</p>
  </div>
</template>

<style scoped>
.after-fill { display: grid; gap: 10px; }
.rows { list-style: none; margin: 0; padding: 0; display: grid; gap: 4px; }
.rows li { display: flex; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
.rows small { color: var(--muted); }
.actions { display: flex; gap: 6px; flex-wrap: wrap; }
.notice, .error { margin: 0; }
.error { color: var(--red, #b42318); }
</style>
