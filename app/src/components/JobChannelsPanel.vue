<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { z } from 'zod'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { friendlyRecruitmentError, type ChannelLite } from '@/lib/jobWorkspace'

/**
 * Where the job is listed (plan 017). One row per channel:
 * - careers: the owned listing — publish / unpublish here; live listings
 *   appear on the public careers page (plan 019).
 * - job boards / social with a provider: shown as not connected until an
 *   integration is authorised (no fake publishing).
 * - manual: a posting somebody made by hand — recorded with its URL and who
 *   verified it, the blueprint's manual-publication pattern.
 * A row published from an older description revision is flagged out of date.
 */

type Channel = { key: string; label: string; kind: string }
type JobChannel = ChannelLite & {
  id: string
  publication_url: string | null
  updated_at: string
  verified_by: { full_name: string } | null
  published_by: { full_name: string } | null
}

const props = defineProps<{
  jobId: string
  companyId: string
  companyCode: string
  jobStatus: string
  descriptionRevision: number
}>()
const emit = defineEmits<{ changed: [channels: ChannelLite[]]; opened: [] }>()

const auth = useAuthStore()
const channels = ref<Channel[]>([])
const rows = ref<JobChannel[]>([])
const integrations = ref<{ provider_key: string; status: string }[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const busyKey = ref<string | null>(null)
const recordingKey = ref<string | null>(null)
const manualUrl = ref('')

const canPublish = computed(() => auth.can(props.companyId, 'jobs.publish'))

const urlInput = z.string().trim().url('Enter the full address of the posting (https://…).')

function rowFor(key: string): JobChannel | null {
  return rows.value.find((r) => r.channel_key === key) ?? null
}

function statusOf(key: string): string {
  return rowFor(key)?.status ?? 'not_selected'
}

function isOutOfDate(key: string): boolean {
  const row = rowFor(key)
  return !!row && ['submitted', 'live'].includes(row.status) && (row.published_revision ?? 0) < props.descriptionRevision
}

function providerFor(channel: Channel): string | null {
  if (channel.key === 'linkedin') return 'linkedin_recruitment'
  if (channel.key === 'indeed') return 'indeed'
  return null
}

function providerConnected(channel: Channel): boolean {
  const key = providerFor(channel)
  return !!key && integrations.value.some((i) => i.provider_key === key && i.status === 'connected')
}

function badgeClass(status: string): string {
  if (status === 'live') return 'green'
  if (status === 'submitted' || status === 'queued') return 'blue'
  if (status === 'action_required' || status === 'failed') return 'amber'
  return ''
}

function linkLabel(url: string): string {
  return url.replace(/^https?:\/\//i, '').replace(/\/$/, '')
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [channelsRes, rowsRes, integrationsRes] = await Promise.all([
    supabase.from('channels').select('key, label, kind').is('archived_at', null).order('key'),
    supabase
      .from('job_channels')
      .select(
        `id, channel_key, status, published_revision, publication_url, updated_at,
         verified_by:people!job_channels_verified_by_fkey(full_name),
         published_by:people!job_channels_published_by_fkey(full_name)`,
      )
      .eq('job_id', props.jobId),
    supabase.from('integrations').select('provider_key, status').eq('company_id', props.companyId),
  ])
  if (channelsRes.error || rowsRes.error) {
    error.value = 'Could not load channels. Check your access and connection.'
    console.error('Channels load failed:', channelsRes.error?.message ?? rowsRes.error?.message)
  }
  channels.value = (channelsRes.data ?? []) as Channel[]
  rows.value = (rowsRes.data ?? []) as JobChannel[]
  integrations.value = integrationsRes.data ?? []
  loading.value = false
  emit('changed', rows.value)
}

async function upsert(key: string, patch: Record<string, unknown>): Promise<boolean> {
  error.value = null
  busyKey.value = key
  const { error: err } = await supabase
    .from('job_channels')
    .upsert({ job_id: props.jobId, channel_key: key, ...patch }, { onConflict: 'job_id,channel_key' })
  busyKey.value = null
  if (err) {
    error.value = friendlyRecruitmentError(err.message)
    return false
  }
  await load()
  return true
}

/**
 * Publishing the first listing opens a ready job. Anything else (on hold,
 * closed, filled) stays put — reopening is an explicit action on Overview.
 */
async function openJobIfNeeded(): Promise<void> {
  if (props.jobStatus !== 'ready') return
  // A refused UPDATE matches zero rows under RLS (jobs.publish does not imply
  // jobs.edit), so select the row back and treat "nothing came back" as a refusal.
  const { data, error: err } = await supabase
    .from('jobs')
    .update({ status: 'open' })
    .eq('id', props.jobId)
    .select('id')
    .maybeSingle()
  if (err || !data) {
    const reason = err ? friendlyRecruitmentError(err.message) : 'opening a job needs jobs.edit in this company'
    error.value = `Listed, but the job could not be opened: ${reason}`
    return
  }
  emit('opened')
}

async function publishCareers(): Promise<void> {
  const ok = await upsert('careers', {
    status: 'live',
    published_revision: props.descriptionRevision,
    published_by: auth.personId,
    last_error: null,
  })
  if (ok) await openJobIfNeeded()
}

async function unpublishCareers(): Promise<void> {
  await upsert('careers', { status: 'closed' })
}

function startRecording(key: string): void {
  recordingKey.value = key
  manualUrl.value = rowFor(key)?.publication_url ?? ''
  error.value = null
}

async function saveManual(key: string): Promise<void> {
  if (props.jobStatus === 'draft') {
    error.value = 'Mark the job ready before recording a posting.'
    return
  }
  const parsed = urlInput.safeParse(manualUrl.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the address.'
    return
  }
  const ok = await upsert(key, {
    status: 'submitted',
    publication_url: parsed.data,
    published_revision: props.descriptionRevision,
    verified_by: auth.personId,
    published_by: auth.personId,
  })
  if (ok) {
    recordingKey.value = null
    await openJobIfNeeded()
  }
}

async function closeManual(key: string): Promise<void> {
  await upsert(key, { status: 'closed' })
}

onMounted(load)
defineExpose({ reload: load })
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Channels</h2>
        <p>Where this job is listed. A listing published from an older description is flagged.</p>
      </div>
    </div>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
    <div v-if="loading" class="empty">Loading channels…</div>
    <div v-else>
      <div v-for="c in channels" :key="c.key" class="channel-row">
        <div class="row-text">
          <strong>{{ c.label }}</strong>
          <small>
            <template v-if="c.kind === 'careers'">
              Owned listing ·
              <a v-if="statusOf(c.key) === 'live'" :href="`/careers/${companyCode.toLowerCase()}/${jobId}`" target="_blank" rel="noopener">open the public page</a>
              <template v-else>publishes to /careers/{{ companyCode.toLowerCase() }}</template>
            </template>
            <template v-else-if="c.kind === 'manual'">Posted by hand somewhere else — record the link so it is tracked.</template>
            <template v-else-if="providerConnected(c)">Connected · publishing arrives with the provider integration.</template>
            <template v-else>Not connected · configure the provider under the company's Integrations.</template>
            <template v-if="rowFor(c.key)?.publication_url">
              ·
              <a :href="rowFor(c.key)!.publication_url!" target="_blank" rel="noopener">
                {{ linkLabel(rowFor(c.key)!.publication_url!) }}
              </a>
            </template>
            <template v-if="rowFor(c.key)?.verified_by"> · verified by {{ rowFor(c.key)!.verified_by!.full_name }}</template>
            <template v-else-if="rowFor(c.key)?.published_by"> · by {{ rowFor(c.key)!.published_by!.full_name }}</template>
          </small>
          <form v-if="recordingKey === c.key" class="manual-form" @submit.prevent="saveManual(c.key)">
            <input id="manual-url" v-model="manualUrl" inputmode="url" placeholder="https://…" aria-label="Posting address" />
            <button class="button small-btn" type="submit" :disabled="busyKey === c.key">Save posting</button>
            <button class="button secondary small-btn" type="button" @click="recordingKey = null">Cancel</button>
          </form>
        </div>
        <span v-if="isOutOfDate(c.key)" class="badge amber">Out of date</span>
        <span class="badge" :class="badgeClass(statusOf(c.key))">{{ statusOf(c.key).replace('_', ' ') }}</span>
        <div v-if="canPublish" class="row-actions">
          <template v-if="c.kind === 'careers'">
            <button
              v-if="statusOf(c.key) !== 'live' || isOutOfDate(c.key)"
              class="button secondary small-btn"
              type="button"
              :disabled="busyKey === c.key || jobStatus === 'draft'"
              :title="jobStatus === 'draft' ? 'Mark the job ready first' : undefined"
              @click="publishCareers"
            >
              {{ isOutOfDate(c.key) ? 'Republish' : 'Publish' }}
            </button>
            <button
              v-if="statusOf(c.key) === 'live'"
              class="button secondary small-btn"
              type="button"
              :disabled="busyKey === c.key"
              @click="unpublishCareers"
            >
              Unpublish
            </button>
          </template>
          <template v-else-if="c.kind === 'manual'">
            <button
              v-if="recordingKey !== c.key"
              class="button secondary small-btn"
              type="button"
              :disabled="busyKey === c.key || jobStatus === 'draft'"
              :title="jobStatus === 'draft' ? 'Mark the job ready first' : undefined"
              @click="startRecording(c.key)"
            >
              {{ rowFor(c.key)?.publication_url ? 'Update posting' : 'Record posting' }}
            </button>
            <button
              v-if="statusOf(c.key) === 'submitted' || statusOf(c.key) === 'live'"
              class="button secondary small-btn"
              type="button"
              :disabled="busyKey === c.key"
              @click="closeManual(c.key)"
            >
              Mark closed
            </button>
          </template>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.channel-row {
  display: flex;
  align-items: center;
  gap: 13px;
  padding: 15px 24px;
  border-top: 1px solid #edf0eb;
  flex-wrap: wrap;
}
.row-text { flex: 1; min-width: 240px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; line-height: 1.6; }
.row-text small a { color: var(--green); text-decoration: none; }
.row-text small a:hover { text-decoration: underline; }
.manual-form { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
.manual-form input {
  flex: 1;
  min-width: 220px;
  border: 1px solid #dce3d7;
  padding: 8px 10px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
}
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
