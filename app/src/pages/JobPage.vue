<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import AddCandidateDialog from '@/components/AddCandidateDialog.vue'
import ConfirmHireDialog from '@/components/ConfirmHireDialog.vue'
import JobStepper from '@/components/JobStepper.vue'
import ScreeningQuestionsEditor from '@/components/ScreeningQuestionsEditor.vue'
import JobChannelsPanel from '@/components/JobChannelsPanel.vue'
import JobPromotionPanel from '@/components/JobPromotionPanel.vue'
import JobActivityPanel from '@/components/JobActivityPanel.vue'
import JobInterviewsPanel from '@/components/JobInterviewsPanel.vue'
import { criteriaFor, criteriaInput, type Criterion } from '@/lib/interviews'
import {
  currentStep,
  friendlyRecruitmentError,
  isPublished,
  jobStatusActions,
  salvageQuestions,
  screeningQuestionsInput,
  type ChannelLite,
  type ScreeningQuestion,
} from '@/lib/jobWorkspace'

/**
 * One approved role's workspace (plan 017, blueprint §4): Overview (the
 * five-step journey, facts, pipeline counts, status actions) · Description
 * (+ screening questions) · Channels · Applications · Promotion · Activity.
 * The active tab is ?tab= so every panel is deep-linkable. Interviews & Offer
 * arrives with plan 018.
 */

type TabId = 'overview' | 'description' | 'channels' | 'applications' | 'interviews' | 'promotion' | 'activity'

const TABS: { id: TabId; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'description', label: 'Description' },
  { id: 'channels', label: 'Channels' },
  { id: 'applications', label: 'Applications' },
  { id: 'interviews', label: 'Interviews & Offer' },
  { id: 'promotion', label: 'Promotion' },
  { id: 'activity', label: 'Activity' },
]

type Job = {
  id: string
  title: string
  description: string | null
  description_revision: number
  screening_questions: unknown
  scorecard_criteria: unknown
  status: string
  company_id: string
  company: { name: string; short_code: string } | null
  request: {
    title: string
    headcount: number
    target_start_date: string | null
    hiring_manager: { full_name: string } | null
  } | null
}

type ApplicationRow = {
  id: string
  stage_key: string
  employment_period_id: string | null
  next_action: string | null
  next_action_due: string | null
  candidate: { id: string; full_name: string; email: string | null } | null
  owner: { full_name: string } | null
  employment_period: { person_id: string } | null
}

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const jobId = route.params.jobId as string

const job = ref<Job | null>(null)
const applications = ref<ApplicationRow[]>([])
const channels = ref<ChannelLite[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const appError = ref<string | null>(null)
const actionError = ref<string | null>(null)
const statusError = ref<string | null>(null)
const busyId = ref<string | null>(null)
const statusBusy = ref(false)

const descriptionDraft = ref('')
const questionsDraft = ref<ScreeningQuestion[]>([])
const criteriaDraft = ref<Criterion[]>([])
const descSaving = ref(false)
const descError = ref<string | null>(null)
const descSaved = ref(false)
// Stored questions in an unrecognisable shape: never save over them.
const questionsUnreadable = ref(false)

const addCandidateDialog = ref<InstanceType<typeof AddCandidateDialog> | null>(null)
const confirmHireDialog = ref<InstanceType<typeof ConfirmHireDialog> | null>(null)
const channelsPanel = ref<InstanceType<typeof JobChannelsPanel> | null>(null)
const activityPanel = ref<InstanceType<typeof JobActivityPanel> | null>(null)

const activeTab = computed<TabId>(() => {
  const raw = route.query.tab
  const id = Array.isArray(raw) ? raw[0] : raw
  return TABS.some((t) => t.id === id) ? (id as TabId) : 'overview'
})

function selectTab(id: TabId): void {
  router.replace({ query: { tab: id } })
}

const canEdit = computed(() => (job.value ? auth.can(job.value.company_id, 'jobs.edit') : false))
const hiredCount = computed(() => applications.value.filter((a) => a.stage_key === 'hired').length)
const activeCount = computed(
  () => applications.value.filter((a) => !['hired', 'rejected', 'withdrawn'].includes(a.stage_key)).length,
)
const liveChannels = computed(() => channels.value.filter(isPublished).length)

const step = computed(() =>
  currentStep({
    status: job.value?.status ?? 'draft',
    channels: channels.value,
    applications: applications.value.length,
    hired: hiredCount.value,
  }),
)

const statusActions = computed(() =>
  job.value
    ? jobStatusActions({ status: job.value.status, hasDescription: (job.value.description ?? '').trim().length > 0 })
    : [],
)

const stageCounts = computed(() => {
  const counts: Record<string, number> = {}
  for (const a of applications.value) counts[a.stage_key] = (counts[a.stage_key] ?? 0) + 1
  return counts
})

function jobBadgeClass(status: string): string {
  if (status === 'open') return 'green'
  if (status === 'filled' || status === 'ready') return 'blue'
  if (status === 'on_hold') return 'amber'
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
      `id, title, description, description_revision, screening_questions, scorecard_criteria, status, company_id,
       company:companies(name, short_code),
       request:hiring_requests(title, headcount, target_start_date,
         hiring_manager:people!hiring_requests_hiring_manager_id_fkey(full_name))`,
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
  const salvaged = salvageQuestions(data.screening_questions)
  questionsDraft.value = salvaged.questions
  questionsUnreadable.value = salvaged.lossy
  criteriaDraft.value = criteriaFor(data.scorecard_criteria)
}

function updateCriterion(index: number, patch: Partial<Criterion>): void {
  criteriaDraft.value = criteriaDraft.value.map((c, i) => (i === index ? { ...c, ...patch } : c))
}

function addCriterion(): void {
  criteriaDraft.value = [...criteriaDraft.value, { id: crypto.randomUUID(), label: '' }]
}

function removeCriterion(index: number): void {
  criteriaDraft.value = criteriaDraft.value.filter((_, i) => i !== index)
}

async function loadApplications(): Promise<void> {
  appError.value = null
  const { data, error: err } = await supabase
    .from('applications')
    .select(
      `id, stage_key, employment_period_id, next_action, next_action_due,
       candidate:candidates(id, full_name, email),
       owner:people!applications_owner_id_fkey(full_name),
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

async function loadChannels(): Promise<void> {
  const { data } = await supabase
    .from('job_channels')
    .select('channel_key, status, published_revision')
    .eq('job_id', jobId)
  channels.value = (data ?? []) as ChannelLite[]
}

/** Saving bumps the revision so published listings can tell they are stale. */
async function saveDescription(): Promise<void> {
  if (!job.value) return
  descError.value = null
  descSaved.value = false
  if (questionsUnreadable.value) {
    descError.value = 'The stored screening questions are in an unexpected format; saving would erase them. Ask an admin to repair them first.'
    return
  }
  const parsed = screeningQuestionsInput.safeParse(questionsDraft.value)
  if (!parsed.success) {
    descError.value = parsed.error.issues[0]?.message ?? 'Check the screening questions.'
    return
  }
  const criteria = criteriaInput.safeParse(criteriaDraft.value)
  if (!criteria.success) {
    descError.value = criteria.error.issues[0]?.message ?? 'Check the scorecard criteria.'
    return
  }
  descSaving.value = true
  const revision = job.value.description_revision + 1
  const { error: err } = await supabase
    .from('jobs')
    .update({
      description: descriptionDraft.value,
      screening_questions: parsed.data,
      scorecard_criteria: criteria.data,
      description_revision: revision,
    })
    .eq('id', job.value.id)
  descSaving.value = false
  if (err) {
    descError.value = friendlyJobsError(err.message)
    return
  }
  job.value = {
    ...job.value,
    description: descriptionDraft.value,
    screening_questions: parsed.data,
    description_revision: revision,
  }
  questionsDraft.value = parsed.data
  descSaved.value = true
}

async function setStatus(to: string): Promise<void> {
  if (!job.value) return
  statusError.value = null
  statusBusy.value = true
  const { data, error: err } = await supabase
    .from('jobs')
    .update({ status: to })
    .eq('id', job.value.id)
    .select('status')
    .maybeSingle()
  statusBusy.value = false
  if (err || !data) {
    statusError.value = friendlyJobsError(err?.message ?? 'row-level security')
    return
  }
  job.value = { ...job.value, status: data.status }
}

function onChannelsChanged(next: ChannelLite[]): void {
  channels.value = next
}

async function onJobOpened(): Promise<void> {
  await loadJob()
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
  await Promise.all([loadApplications(), loadJob()])
}

function friendlyJobsError(message: string): string {
  if (/row-level security/.test(message)) return 'This change needs jobs.edit in this company.'
  return message
}

function friendlyCandidatesError(message: string): string {
  if (/row-level security/.test(message)) return 'This action needs candidates.review in this company.'
  return friendlyRecruitmentError(message)
}

onMounted(async () => {
  loading.value = true
  await loadJob()
  if (job.value) await Promise.all([loadApplications(), loadChannels()])
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
            <template v-if="job.request.target_start_date"> · target start {{ job.request.target_start_date }}</template>
            <template v-if="job.request.hiring_manager"> · hiring manager {{ job.request.hiring_manager.full_name }}</template>
          </p>
        </div>
        <span class="badge" :class="jobBadgeClass(job.status)">{{ job.status.replace('_', ' ') }}</span>
      </div>

      <JobStepper :current="step" />

      <div class="tabs" role="tablist" aria-label="Job workspace">
        <button
          v-for="tab in TABS"
          :key="tab.id"
          class="tab"
          :class="{ active: activeTab === tab.id }"
          type="button"
          role="tab"
          :aria-selected="activeTab === tab.id"
          @click="selectTab(tab.id)"
        >
          {{ tab.label }}
          <span v-if="tab.id === 'applications' && applications.length" class="count">{{ applications.length }}</span>
        </button>
      </div>

      <!-- Overview -->
      <div v-if="activeTab === 'overview'">
        <div class="metrics">
          <div class="card metric-tile">
            <span class="metric-label">Live listings</span>
            <span class="metric-value">{{ liveChannels }}</span>
          </div>
          <div class="card metric-tile">
            <span class="metric-label">Active candidates</span>
            <span class="metric-value">{{ activeCount }}</span>
          </div>
          <div class="card metric-tile">
            <span class="metric-label">In interview</span>
            <span class="metric-value">{{ stageCounts.interview ?? 0 }}</span>
          </div>
          <div class="card metric-tile">
            <span class="metric-label">Hired</span>
            <span class="metric-value">{{ hiredCount }} / {{ job.request?.headcount ?? 1 }}</span>
          </div>
        </div>

        <div class="card">
          <div class="card-head">
            <div>
              <h2>Status</h2>
              <p>A job opens when its listing goes live; it can pause or close without losing candidates.</p>
            </div>
            <div v-if="canEdit" class="row-actions">
              <button
                v-for="a in statusActions"
                :key="a.to"
                class="button secondary small-btn"
                type="button"
                :disabled="statusBusy"
                @click="setStatus(a.to)"
              >
                {{ a.label }}
              </button>
            </div>
          </div>
          <p v-if="statusError" class="error-note" role="alert" style="margin: 16px 24px">{{ statusError }}</p>
          <dl class="detail-grid">
            <div>
              <dt>Description</dt>
              <dd>{{ (job.description ?? '').trim() ? `Revision ${job.description_revision}` : 'Not written yet' }}</dd>
            </div>
            <div>
              <dt>Screening questions</dt>
              <dd>{{ questionsDraft.length || 'None' }}</dd>
            </div>
            <div>
              <dt>Pipeline</dt>
              <dd>
                <template v-if="applications.length">
                  <span v-for="(n, stage) in stageCounts" :key="stage" class="stage-count">{{ stage }} {{ n }}</span>
                </template>
                <template v-else>No candidates yet</template>
              </dd>
            </div>
            <div>
              <dt>Next step</dt>
              <dd>
                <template v-if="step === 'request'">Write the description, then mark the job ready.</template>
                <template v-else-if="step === 'job'">Publish the listing under Channels.</template>
                <template v-else-if="step === 'publish'">Candidates will appear under Applications.</template>
                <template v-else-if="step === 'applications'">Move candidates through screening and interview to an offer.</template>
                <template v-else>Hired — close the job once the headcount is met.</template>
              </dd>
            </div>
          </dl>
        </div>
      </div>

      <!-- Description -->
      <div v-else-if="activeTab === 'description'" class="card">
        <div class="card-head">
          <div>
            <h2>Description &amp; screening</h2>
            <p>What candidates read and answer. Saving records a new revision; live listings are flagged until republished.</p>
          </div>
        </div>
        <div class="card-body">
          <label class="field-label" for="job-description">Description</label>
          <textarea
            id="job-description"
            v-model="descriptionDraft"
            rows="8"
            :readonly="!canEdit"
            placeholder="Describe the role, responsibilities, and requirements…"
          ></textarea>
          <h3 class="sub-heading">Screening questions</h3>
          <ScreeningQuestionsEditor v-model="questionsDraft" :disabled="!canEdit" />

          <h3 class="sub-heading">Scorecard criteria</h3>
          <p class="sub-hint">What every interviewer rates 1–4. Existing scorecards keep the labels they were scored against.</p>
          <div class="criteria">
            <div v-for="(c, i) in criteriaDraft" :key="c.id" class="criterion-row">
              <input
                class="criterion-label"
                :value="c.label"
                :disabled="!canEdit"
                maxlength="80"
                :aria-label="`Criterion ${i + 1}`"
                @input="updateCriterion(i, { label: ($event.target as HTMLInputElement).value })"
              />
              <input
                class="criterion-description"
                :value="c.description ?? ''"
                :disabled="!canEdit"
                maxlength="200"
                placeholder="What good looks like (optional)"
                :aria-label="`Description for criterion ${i + 1}`"
                @input="updateCriterion(i, { description: ($event.target as HTMLInputElement).value })"
              />
              <button
                class="button secondary small-btn"
                type="button"
                :disabled="!canEdit || criteriaDraft.length <= 1"
                @click="removeCriterion(i)"
              >
                Remove
              </button>
            </div>
            <button
              class="button secondary small-btn"
              type="button"
              :disabled="!canEdit"
              @click="addCriterion"
            >
              Add criterion
            </button>
          </div>
          <p v-if="descError" class="error-note" role="alert">{{ descError }}</p>
          <p v-if="descSaved" class="success-note">Description saved (revision {{ job.description_revision }}).</p>
          <div v-if="canEdit" class="actions">
            <button class="button" type="button" :disabled="descSaving" @click="saveDescription">
              {{ descSaving ? 'Saving…' : 'Save description' }}
            </button>
          </div>
        </div>
      </div>

      <!-- Channels -->
      <JobChannelsPanel
        v-else-if="activeTab === 'channels'"
        ref="channelsPanel"
        :job-id="job.id"
        :company-id="job.company_id"
        :company-code="job.company?.short_code ?? ''"
        :job-status="job.status"
        :description-revision="job.description_revision"
        @changed="onChannelsChanged"
        @opened="onJobOpened"
      />

      <!-- Applications -->
      <div v-else-if="activeTab === 'applications'" class="card applications-card">
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
        <p v-if="actionError" class="error-note" role="alert" style="margin: 16px 24px">{{ actionError }}</p>
        <div v-if="!applications.length" class="empty">No candidates yet. Add one to start the pipeline.</div>
        <div v-else>
          <div v-for="a in applications" :key="a.id" class="application-row">
            <div class="row-text">
              <router-link class="candidate-link" :to="{ name: 'application', params: { applicationId: a.id } }">
                <strong>{{ a.candidate?.full_name ?? '—' }}</strong>
              </router-link>
              <small>
                {{ a.candidate?.email ?? '—' }}
                <template v-if="a.owner"> · {{ a.owner.full_name }}</template>
                <template v-if="a.next_action"> · next: {{ a.next_action }}<template v-if="a.next_action_due"> by {{ a.next_action_due }}</template></template>
              </small>
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
                <button v-if="a.stage_key === 'new'" class="button secondary small-btn" type="button" :disabled="busyId === a.id" @click="moveToScreening(a)">
                  Move to screening
                </button>
                <button v-if="a.stage_key === 'screening'" class="button secondary small-btn" type="button" :disabled="busyId === a.id" @click="moveToInterview(a)">
                  Move to interview
                </button>
                <button v-if="a.stage_key === 'interview'" class="button secondary small-btn" type="button" :disabled="busyId === a.id" @click="prepareOffer(a)">
                  Prepare offer
                </button>
                <button v-if="a.stage_key === 'offer'" class="button secondary small-btn" type="button" :disabled="busyId === a.id" @click="openConfirmHire(a)">
                  Confirm hire
                </button>
                <button v-if="!isTerminal(a.stage_key)" class="button secondary small-btn" type="button" :disabled="busyId === a.id" @click="reject(a)">
                  Reject
                </button>
              </template>
            </div>
          </div>
        </div>
      </div>

      <!-- Interviews & Offer -->
      <JobInterviewsPanel v-else-if="activeTab === 'interviews'" :job-id="job.id" />

      <!-- Promotion -->
      <JobPromotionPanel
        v-else-if="activeTab === 'promotion'"
        :job-id="job.id"
        :company-id="job.company_id"
        :job-title="job.title"
        :company-name="job.company?.name ?? ''"
        :description="job.description ?? ''"
      />

      <!-- Activity -->
      <JobActivityPanel v-else-if="activeTab === 'activity'" ref="activityPanel" :job-id="job.id" />
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
  margin-bottom: 18px;
}
.job-meta { margin: 4px 0 0; font-size: 11px; color: var(--muted); }
.tabs { display: flex; gap: 22px; border-bottom: 1px solid var(--line); margin-bottom: 22px; overflow: auto; }
.tab {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  border: 0;
  background: transparent;
  color: var(--muted);
  padding: 0 1px 13px;
  border-bottom: 2px solid transparent;
  border-radius: 0;
  white-space: nowrap;
  font-size: 12px;
}
.tab.active { color: var(--green); font-weight: 600; border-bottom-color: var(--green); }
.tab .count {
  font-size: 10px;
  padding: 1px 6px;
  border-radius: 999px;
  background: #f0f1ef;
  color: var(--muted);
}
.metrics { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; margin-bottom: 22px; }
@media (max-width: 900px) { .metrics { grid-template-columns: repeat(2, 1fr); } }
.metric-tile { display: flex; flex-direction: column; gap: 8px; padding: 18px 20px; }
.metric-label { font-size: 11px; color: var(--muted); font-weight: 550; }
.metric-value { font-size: 26px; font-weight: 750; letter-spacing: -0.02em; }
.detail-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 18px 20px; padding: 20px 24px 23px; margin: 0; }
.detail-grid dt { font-size: 10px; color: var(--muted); margin-bottom: 6px; }
.detail-grid dd { margin: 0; font-size: 12px; line-height: 1.6; }
@media (max-width: 560px) { .detail-grid { grid-template-columns: 1fr; } }
.stage-count { display: inline-block; margin-right: 10px; text-transform: capitalize; }
.field-label { display: block; font-size: 11px; font-weight: 550; color: #566653; margin-bottom: 7px; }
.sub-heading { font-size: 12px; margin: 20px 0 10px; }
.sub-hint { margin: -6px 0 10px; font-size: 11px; color: var(--muted); }
.criteria { display: grid; gap: 8px; }
.criterion-row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.criterion-label, .criterion-description {
  border: 1px solid #dce3d7;
  padding: 9px 11px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
}
.criterion-label { flex: 1; min-width: 160px; }
.criterion-description { flex: 2; min-width: 220px; }
.criteria .small-btn { align-self: center; }
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
textarea[readonly] { background: #fafbf9; }
.success-note { margin: 12px 0 0; font-size: 12px; color: #3e744e; }
.actions { display: flex; justify-content: flex-end; margin-top: 14px; }
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
.candidate-link { text-decoration: none; color: inherit; }
.candidate-link:hover strong { color: var(--green); text-decoration: underline; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
