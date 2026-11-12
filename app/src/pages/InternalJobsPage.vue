<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useDialogStore } from '@/stores/dialogs'

/**
 * The internal job board (0107; spec 3.5, section 4). Every job live on the
 * `internal` channel, across the group. Applying is one step; the person's
 * current manager does not see the application until an offer is made, and
 * the page says so before they apply.
 */
type InternalJob = { id: string; title: string; company: string; text: string; salary: string | null; until: string | null; applied: boolean }

const dialogs = useDialogStore()
const jobs = ref<InternalJob[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const openId = ref<string | null>(null)
const busyId = ref<string | null>(null)

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase.rpc('internal_jobs')
  loading.value = false
  if (err) {
    console.error('internal_jobs failed:', err.message)
    error.value = 'Could not load the internal jobs.'
    return
  }
  jobs.value = (data ?? []) as unknown as InternalJob[]
}

async function apply(job: InternalJob): Promise<void> {
  const answer = await dialogs.askReason({
    title: `Apply for ${job.title}?`,
    eyebrow: job.company,
    hint: 'HR sees your application straight away. Your current manager is not told until an offer is about to be made.',
    label: 'A note for HR (optional)',
    required: false,
    confirmLabel: 'Apply',
  })
  if (!answer) return
  busyId.value = job.id
  error.value = null
  notice.value = null
  const { error: err } = await supabase.rpc('apply_internally', { p_job_id: job.id, p_note: answer.reason || null })
  busyId.value = null
  if (err) {
    console.error('apply_internally failed:', err.message)
    error.value = err.message
    return
  }
  notice.value = `You applied for ${job.title}. HR will be in touch.`
  await load()
}

onMounted(load)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">My workspace</div>
        <h1>Internal jobs</h1>
        <p class="lede">Open roles across the group, for people already here.</p>
      </div>
    </div>
    <p v-if="notice" class="notice" role="status">{{ notice }}</p>
    <p v-if="error" class="error" role="alert">{{ error }}</p>
    <div class="card jobs-card">
      <div v-if="loading" class="empty">Loading…</div>
      <div v-else-if="!jobs.length" class="empty" data-testid="internal-jobs-empty">No internal openings right now.</div>
      <article v-for="j in jobs" :key="j.id" class="job" :data-testid="`internal-job-${j.id}`">
        <div class="job-main">
          <div class="eyebrow">{{ j.company }}<template v-if="j.until"> · until {{ j.until }}</template></div>
          <strong>{{ j.title }}</strong>
          <small v-if="j.salary">{{ j.salary }}</small>
          <button class="linkish" type="button" @click="openId = openId === j.id ? null : j.id">{{ openId === j.id ? 'Hide details' : 'Read more' }}</button>
          <p v-if="openId === j.id" class="text">{{ j.text || 'No description yet.' }}</p>
        </div>
        <span v-if="j.applied" class="badge green">Applied</span>
        <button v-else class="button small-btn" type="button" :disabled="busyId === j.id" @click="apply(j)">Apply</button>
      </article>
    </div>
  </div>
</template>

<style scoped>
.jobs-card { padding: 0 24px; }
.lede { margin: 4px 0 0; color: var(--muted); }
.job { display: flex; justify-content: space-between; gap: 12px; padding: 12px 0; border-top: 1px solid var(--line); flex-wrap: wrap; align-items: flex-start; }
.job-main { display: grid; gap: 2px; min-width: 0; flex: 1 1 280px; }
.job-main small { color: var(--muted); }
.text { white-space: pre-line; margin: 6px 0 0; max-width: 70ch; }
.linkish { background: none; border: 0; padding: 0; color: var(--green); cursor: pointer; justify-self: start; font-size: 12px; }
.notice, .error { margin: 0 0 12px; }
.error { color: var(--red, #b42318); }
</style>
