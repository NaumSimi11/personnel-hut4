<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import AddCandidateDialog from '@/components/AddCandidateDialog.vue'
import ConfirmHireDialog from '@/components/ConfirmHireDialog.vue'

type Job = {
  id: string
  title: string
  description: string | null
  status: string
  company_id: string
  company: { name: string } | null
  request: { title: string; headcount: number; target_start_date: string | null } | null
}

type ApplicationRow = {
  id: string
  stage_key: string
  employment_period_id: string | null
  candidate: { id: string; full_name: string; email: string | null } | null
  employment_period: { person_id: string } | null
}

const route = useRoute()
const auth = useAuthStore()
const jobId = route.params.jobId as string

const job = ref<Job | null>(null)
const applications = ref<ApplicationRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const appError = ref<string | null>(null)
const actionError = ref<string | null>(null)
const busyId = ref<string | null>(null)

const descriptionDraft = ref('')
const descSaving = ref(false)
const descError = ref<string | null>(null)

const addCandidateDialog = ref<InstanceType<typeof AddCandidateDialog> | null>(null)
const confirmHireDialog = ref<InstanceType<typeof ConfirmHireDialog> | null>(null)

function jobBadgeClass(status: string): string {
  if (status === 'open') return 'green'
  if (status === 'filled') return 'blue'
  return ''
}

function stageBadgeClass(stage: string): string {
  if (stage === 'hired') return 'green'
  if (stage === 'offer') return 'amber'
  if (stage === 'rejected') return ''
  return 'blue'
}

function isTerminal(stage: string): boolean {
  return stage === 'hired' || stage === 'rejected' || stage === 'withdrawn'
}

async function loadJob(): Promise<void> {
  error.value = null
  const { data, error: err } = await supabase
    .from('jobs')
    .select(
      `id, title, description, status, company_id,
       company:companies(name),
       request:hiring_requests(title, headcount, target_start_date)`,
    )
    .eq('id', jobId)
    .maybeSingle()
  if (err || !data) {
    error.value = 'Job not found or not visible with your access.'
    console.error('Job load failed:', err?.message)
    return
  }
  job.value = data as Job
  descriptionDraft.value = data.description ?? ''
}

async function loadApplications(): Promise<void> {
  appError.value = null
  const { data, error: err } = await supabase
    .from('applications')
    .select(
      `id, stage_key, employment_period_id,
       candidate:candidates(id, full_name, email),
       employment_period:employment_periods!applications_employment_period_id_fkey(person_id)`,
    )
    .eq('job_id', jobId)
    .order('created_at', { ascending: true })
  if (err) {
    appError.value = 'Could not load applications. Check your access and connection.'
    console.error('Applications load failed:', err.message)
    return
  }
  applications.value = (data ?? []) as ApplicationRow[]
}

async function saveDescription(): Promise<void> {
  if (!job.value) return
  descError.value = null
  descSaving.value = true
  const { error: err } = await supabase
    .from('jobs')
    .update({ description: descriptionDraft.value })
    .eq('id', job.value.id)
  descSaving.value = false
  if (err) {
    descError.value = friendlyJobsError(err.message)
    return
  }
  job.value = { ...job.value, description: descriptionDraft.value }
}

async function updateStage(app: ApplicationRow, toStage: string, body?: string): Promise<void> {
  actionError.value = null
  busyId.value = app.id
  const { error: err } = await supabase
    .from('applications')
    .update({ stage_key: toStage })
    .eq('id', app.id)
  if (!err) {
    await supabase.from('application_events').insert({
      application_id: app.id,
      kind: 'stage_change',
      from_stage_key: app.stage_key,
      to_stage_key: toStage,
      actor_id: auth.personId,
      body: body ?? null,
    })
  }
  busyId.value = null
  if (err) {
    actionError.value = friendlyCandidatesError(err.message)
    return
  }
  await loadApplications()
}

function moveToScreening(app: ApplicationRow): void {
  void updateStage(app, 'screening')
}
function moveToInterview(app: ApplicationRow): void {
  void updateStage(app, 'interview')
}
function prepareOffer(app: ApplicationRow): void {
  void updateStage(app, 'offer')
}
function reject(app: ApplicationRow): void {
  const reason = window.prompt('Why is this application being rejected?')
  if (!reason || !reason.trim()) return
  void updateStage(app, 'rejected', reason.trim())
}

function openConfirmHire(app: ApplicationRow): void {
  confirmHireDialog.value?.open({
    applicationId: app.id,
    candidateName: app.candidate?.full_name ?? '',
    jobTitle: job.value?.title ?? '',
  })
}

async function onHired(): Promise<void> {
  await loadApplications()
}

function friendlyJobsError(message: string): string {
  if (/row-level security/.test(message)) return 'Saving needs jobs.edit in this company.'
  return message
}

function friendlyCandidatesError(message: string): string {
  if (/row-level security/.test(message)) return 'This action needs candidates.review in this company.'
  return message
}

onMounted(async () => {
  loading.value = true
  await loadJob()
  if (job.value) await loadApplications()
  loading.value = false
})
</script>

<template>
  <div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-if="loading" class="empty">Loading job…</div>

    <template v-else-if="job">
      <router-link :to="{ name: 'hiring' }" class="back-link">← Back to Hiring</router-link>
      <div class="page-head">
        <div>
          <div class="eyebrow">Recruitment / {{ job.company?.name ?? '—' }}</div>
          <h1>{{ job.title }}</h1>
          <p v-if="job.request" class="job-meta">
            From hiring request "{{ job.request.title }}" · headcount {{ job.request.headcount }}
            <template v-if="job.request.target_start_date">
              · target start {{ job.request.target_start_date }}
            </template>
          </p>
        </div>
        <span class="badge" :class="jobBadgeClass(job.status)">{{ job.status.replace('_', ' ') }}</span>
      </div>

      <div class="card description-card">
        <div class="card-head">
          <div>
            <h2>Description</h2>
            <p>Shown to candidates once the job is published to a channel.</p>
          </div>
        </div>
        <div class="card-body">
          <textarea
            v-model="descriptionDraft"
            rows="6"
            placeholder="Describe the role, responsibilities, and requirements…"
          ></textarea>
          <p v-if="descError" class="error-note" role="alert">{{ descError }}</p>
          <div class="actions">
            <button class="button" type="button" :disabled="descSaving" @click="saveDescription">
              {{ descSaving ? 'Saving…' : 'Save' }}
            </button>
          </div>
        </div>
      </div>

      <div class="card applications-card">
        <div class="card-head">
          <div>
            <h2>Applications</h2>
            <p>Candidates moving through this job's pipeline.</p>
          </div>
          <button class="button secondary" type="button" @click="addCandidateDialog?.open()">
            Add candidate
          </button>
        </div>
        <p v-if="appError" class="error-note" role="alert" style="margin: 16px 24px">{{ appError }}</p>
        <p v-if="actionError" class="error-note" role="alert" style="margin: 16px 24px">
          {{ actionError }}
        </p>
        <div v-if="!applications.length" class="empty">
          No candidates yet. Add one to start the pipeline.
        </div>
        <div v-else>
          <div v-for="a in applications" :key="a.id" class="application-row">
            <div class="row-text">
              <strong>{{ a.candidate?.full_name ?? '—' }}</strong>
              <small>{{ a.candidate?.email ?? '—' }}</small>
            </div>
            <span class="badge" :class="stageBadgeClass(a.stage_key)">{{ a.stage_key }}</span>
            <div class="row-actions">
              <router-link
                v-if="a.stage_key === 'hired' && a.employment_period?.person_id"
                class="button secondary small-btn"
                :to="{ name: 'person', params: { personId: a.employment_period.person_id } }"
              >
                Open employee profile
              </router-link>
              <template v-else-if="a.stage_key !== 'hired'">
                <button
                  v-if="a.stage_key === 'new'"
                  class="button secondary small-btn"
                  type="button"
                  :disabled="busyId === a.id"
                  @click="moveToScreening(a)"
                >
                  Move to screening
                </button>
                <button
                  v-if="a.stage_key === 'screening'"
                  class="button secondary small-btn"
                  type="button"
                  :disabled="busyId === a.id"
                  @click="moveToInterview(a)"
                >
                  Move to interview
                </button>
                <button
                  v-if="a.stage_key === 'interview'"
                  class="button secondary small-btn"
                  type="button"
                  :disabled="busyId === a.id"
                  @click="prepareOffer(a)"
                >
                  Prepare offer
                </button>
                <button
                  v-if="a.stage_key === 'offer'"
                  class="button secondary small-btn"
                  type="button"
                  :disabled="busyId === a.id"
                  @click="openConfirmHire(a)"
                >
                  Confirm hire
                </button>
                <button
                  v-if="!isTerminal(a.stage_key)"
                  class="button secondary small-btn"
                  type="button"
                  :disabled="busyId === a.id"
                  @click="reject(a)"
                >
                  Reject
                </button>
              </template>
            </div>
          </div>
        </div>
      </div>
    </template>

    <AddCandidateDialog
      v-if="job"
      ref="addCandidateDialog"
      :job-id="job.id"
      :company-id="job.company_id"
      @created="loadApplications"
    />
    <ConfirmHireDialog ref="confirmHireDialog" @hired="onHired" />
  </div>
</template>

<style scoped>
.back-link {
  display: inline-block;
  font-size: 11px;
  color: var(--muted);
  text-decoration: none;
  margin-bottom: 14px;
}
.back-link:hover { color: var(--green); text-decoration: underline; }
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
  margin-bottom: 22px;
}
.job-meta { margin: 4px 0 0; font-size: 11px; color: var(--muted); }
.description-card { margin-bottom: 22px; }
textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 11px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
.actions { display: flex; justify-content: flex-end; margin-top: 12px; }
.application-row {
  display: flex;
  align-items: center;
  gap: 13px;
  padding: 15px 24px;
  border-top: 1px solid #edf0eb;
  flex-wrap: wrap;
}
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
