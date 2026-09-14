<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'

/**
 * The job's audit trail (plan 017): every insert/update the audit trigger
 * recorded for the job, its channels, promotions and applications, newest
 * first. Offers key on the application, not the job — they join the trail
 * with plan 018's Interviews & Offer tab. Read access follows jobs.view /
 * candidates.view (migration 0012). Rows are summarised from before/after —
 * no PII beyond what those rows already carry.
 */

type ActivityRow = {
  id: number
  at: string
  entity_type: string
  entity_id: string | null
  action: string
  before: Record<string, unknown> | null
  after: Record<string, unknown> | null
  actor_person_id: string | null
  actor: { full_name: string } | null
}

const props = defineProps<{ jobId: string }>()

const rows = ref<ActivityRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const ENTITY_LABELS: Record<string, string> = {
  jobs: 'Job',
  job_channels: 'Channel',
  promotions: 'Promotion',
  applications: 'Application',
}

const WATCHED_FIELDS = ['status', 'stage_key', 'description_revision', 'publication_url', 'channel_key']

function summarise(row: ActivityRow): string {
  const after = row.after ?? {}
  const before = row.before ?? {}
  if (row.action === 'INSERT') {
    const what = (after.channel_key as string | undefined) ?? (after.stage_key as string | undefined)
    return what ? `created (${what.replace('_', ' ')})` : 'created'
  }
  if (row.action === 'DELETE') return 'removed'
  const changes = WATCHED_FIELDS.filter((f) => f in after && before[f] !== after[f]).map(
    (f) => `${f.replace('_', ' ')}: ${String(before[f] ?? '—')} → ${String(after[f] ?? '—')}`,
  )
  return changes.length ? changes.join(', ') : 'updated'
}

// The actor embed goes through people RLS: a person the viewer cannot see is
// still a person, not the system.
function actorLabel(row: ActivityRow): string {
  if (row.actor) return row.actor.full_name
  return row.actor_person_id ? 'a colleague' : 'system'
}

function entityLabel(row: ActivityRow): string {
  return ENTITY_LABELS[row.entity_type] ?? row.entity_type
}

function belongsToJob(row: ActivityRow): boolean {
  const rec = row.after ?? row.before ?? {}
  return row.entity_type === 'jobs' ? row.entity_id === props.jobId : rec.job_id === props.jobId
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  // job_id lives inside the jsonb for child rows; the query fetches the
  // recruitment entity types for this job's company slice and filters here.
  const { data, error: err } = await supabase
    .from('activity_log')
    .select(
      'id, at, entity_type, entity_id, action, before, after, actor_person_id, actor:people!activity_log_actor_person_id_fkey(full_name)',
    )
    .in('entity_type', ['jobs', 'job_channels', 'promotions', 'applications'])
    .or(`entity_id.eq.${props.jobId},after->>job_id.eq.${props.jobId},before->>job_id.eq.${props.jobId}`)
    .order('at', { ascending: false })
    .limit(200)
  if (err) {
    error.value = 'Could not load activity. Check your access and connection.'
    console.error('Activity load failed:', err.message)
  } else {
    rows.value = (data as ActivityRow[]).filter(belongsToJob)
  }
  loading.value = false
}

onMounted(load)
defineExpose({ reload: load })
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Activity</h2>
        <p>Who changed what, and when — the job, its listings, promotion and applications.</p>
      </div>
    </div>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
    <div v-if="loading" class="empty">Loading activity…</div>
    <div v-else-if="!rows.length" class="empty">Nothing recorded yet.</div>
    <div v-else>
      <div v-for="row in rows" :key="row.id" class="activity-row">
        <span class="badge">{{ entityLabel(row) }}</span>
        <div class="row-text">
          <strong>{{ summarise(row) }}</strong>
          <small>{{ new Date(row.at).toLocaleString() }} · {{ actorLabel(row) }}</small>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.activity-row {
  display: flex;
  align-items: center;
  gap: 13px;
  padding: 13px 24px;
  border-top: 1px solid #edf0eb;
}
.row-text { flex: 1; min-width: 0; }
.row-text strong { display: block; font-size: 12px; font-weight: 500; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
</style>
