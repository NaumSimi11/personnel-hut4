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
type PostingFields = {
  posting_title: string | null
  posting_text: string | null
  salary_display: string | null
  publish_from: string | null
  publish_until: string | null
}
type JobChannel = ChannelLite & Partial<PostingFields> & {
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
         posting_title, posting_text, salary_display, publish_from, publish_until,
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

// The careers page and the internal job board (0107) publish the same way.
async function publishCareers(key = 'careers'): Promise<void> {
  const ok = await upsert(key, {
    status: 'live',
    published_revision: props.descriptionRevision,
    published_by: auth.personId,
    last_error: null,
  })
  if (ok) await openJobIfNeeded()
}

async function unpublishCareers(key = 'careers'): Promise<void> {
  await upsert(key, { status: 'closed' })
}

// 0107: each channel's own posting — title, text, salary line, publish window (spec 3.4).
const editingPosting = ref<string | null>(null)
const posting = ref({ title: '', text: '', salary: '', from: '', until: '' })
function startPosting(key: string): void {
  const r = rowFor(key) as (JobChannel & PostingFields) | null
  posting.value = {
    title: r?.posting_title ?? '',
    text: r?.posting_text ?? '',
    salary: r?.salary_display ?? '',
    from: r?.publish_from ?? '',
    until: r?.publish_until ?? '',
  }
  editingPosting.value = key
  error.value = null
}
async function savePosting(key: string): Promise<void> {
  const p = posting.value
  if (p.from && p.until && p.until < p.from) {
    error.value = 'The posting ends before it starts.'
    return
  }
  const ok = await upsert(key, {
    posting_title: p.title.trim() || null,
    posting_text: p.text.trim() || null,
    salary_display: p.salary.trim() || null,
    publish_from: p.from || null,
    publish_until: p.until || null,
  })
  if (ok) editingPosting.value = null
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
            <template v-if="c.key === 'internal'">Seen by everyone in the group under Internal jobs; employees apply in one step.</template>
            <template v-else-if="c.kind === 'careers'">
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
          <small v-if="rowFor(c.key)?.publish_from || rowFor(c.key)?.publish_until" class="window">
            Shown {{ rowFor(c.key)?.publish_from ? `from ${rowFor(c.key)!.publish_from}` : '' }} {{ rowFor(c.key)?.publish_until ? `until ${rowFor(c.key)!.publish_until}` : '' }}
          </small>
          <form v-if="editingPosting === c.key" class="posting-form" @submit.prevent="savePosting(c.key)">
            <input :id="`posting-title-${c.key}`" v-model="posting.title" maxlength="120" placeholder="Posting title (defaults to the job title)" aria-label="Posting title" />
            <textarea :id="`posting-text-${c.key}`" v-model="posting.text" rows="5" maxlength="20000" placeholder="Posting text (defaults to the job description)" aria-label="Posting text"></textarea>
            <input :id="`posting-salary-${c.key}`" v-model="posting.salary" maxlength="120" placeholder="Salary shown, e.g. EUR 30–40k (optional)" aria-label="Salary shown" />
            <div class="dates">
              <label :for="`posting-from-${c.key}`">From</label>
              <input :id="`posting-from-${c.key}`" v-model="posting.from" type="date" />
              <label :for="`posting-until-${c.key}`">Until</label>
              <input :id="`posting-until-${c.key}`" v-model="posting.until" type="date" />
            </div>
            <div class="dates">
              <button class="button small-btn" type="submit" :disabled="busyKey === c.key">Save posting</button>
              <button class="button secondary small-btn" type="button" @click="editingPosting = null">Cancel</button>
            </div>
          </form>
          <form v-if="recordingKey === c.key" class="manual-form" @submit.prevent="saveManual(c.key)">
            <input id="manual-url" v-model="manualUrl" inputmode="url" placeholder="https://…" aria-label="Posting address" />
            <button class="button small-btn" type="submit" :disabled="busyKey === c.key">Save posting</button>
            <button class="button secondary small-btn" type="button" @click="recordingKey = null">Cancel</button>
          </form>
        </div>
        <span v-if="isOutOfDate(c.key)" class="badge amber">Out of date</span>
        <span class="badge" :class="badgeClass(statusOf(c.key))">{{ statusOf(c.key).replace('_', ' ') }}</span>
        <div v-if="canPublish" class="row-actions">
          <button v-if="editingPosting !== c.key" class="button secondary small-btn" type="button" @click="startPosting(c.key)">Posting</button>
          <template v-if="c.kind === 'careers'">
            <button
              v-if="statusOf(c.key) !== 'live' || isOutOfDate(c.key)"
              class="button secondary small-btn"
              type="button"
              :disabled="busyKey === c.key || jobStatus === 'draft'"
              :title="jobStatus === 'draft' ? 'Mark the job ready first' : undefined"
              @click="publishCareers(c.key)"
            >
              {{ isOutOfDate(c.key) ? 'Republish' : 'Publish' }}
            </button>
            <button
              v-if="statusOf(c.key) === 'live'"
              class="button secondary small-btn"
              type="button"
              :disabled="busyKey === c.key"
              @click="unpublishCareers(c.key)"
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
.posting-form { display: grid; gap: 6px; margin-top: 8px; }
.posting-form input, .posting-form textarea { min-width: 0; width: 100%; }
.posting-form .dates { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
.posting-form .dates input { width: auto; }
.window { display: block; color: var(--muted); }
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
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; line-height: 1.6; }
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
