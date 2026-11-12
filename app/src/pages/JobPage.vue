<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { candidateQueue, candidateNextStep } from '@/lib/hiringJourney'
import AddCandidateDialog from '@/components/AddCandidateDialog.vue'
import UploadCvsDialog from '@/components/UploadCvsDialog.vue'
import PickFromPoolDialog from '@/components/PickFromPoolDialog.vue'
import AddEmployeeDialog from '@/components/AddEmployeeDialog.vue'
import RejectApplicationDialog from '@/components/RejectApplicationDialog.vue'
import { orderNewestFirst } from '@/lib/applicationQueries'
import { useDialogStore } from '@/stores/dialogs'
import JobStepper from '@/components/JobStepper.vue'
import ScreeningQuestionsEditor from '@/components/ScreeningQuestionsEditor.vue'
import JobChannelsPanel from '@/components/JobChannelsPanel.vue'
import JobPromotionPanel from '@/components/JobPromotionPanel.vue'
import JobActivityPanel from '@/components/JobActivityPanel.vue'
import JobInterviewsPanel from '@/components/JobInterviewsPanel.vue'
import { criteriaFor, criteriaInput, type Criterion } from '@/lib/interviews'
import { missingRecordMessage } from '@/lib/missingRecord'
import StatusDialog, { type OutreachApplication } from '@/components/StatusDialog.vue'
import JobHiringManagerField from '@/components/JobHiringManagerField.vue'
import JobPipelineBoard from '@/components/JobPipelineBoard.vue'
import JobTeamCard from '@/components/JobTeamCard.vue'
import AfterFillCard from '@/components/AfterFillCard.vue'
import { NOT_RESPONDING_DAYS, notResponding, type SubStatusRow } from '@/lib/outreach'
import {
  STAGES,
  STAGE_LABEL,
  closureLine,
  firstOpenStatus,
  noStatusesHint,
  stageName,
  statusFilterGroups,
  statusLabels,
  type StageKey,
} from '@/lib/stageStatuses'
import { setApplicationStatus } from '@/lib/applicationStatus'
import { todayDb } from '@/lib/compensation'
import { LIST_PAGE } from '@/lib/pageAll'
import { createRequestGate } from '@/lib/requestGate'
import { useHiringLookupsStore } from '@/stores/hiringLookups'
import { friendlyDetachError } from '@/lib/detachApplication'
import {
  currentStep,
  friendlyRecruitmentError,
  isPublished,
  filledNote,
  jobHeadcount,
  jobStatusOptions,
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

type TabId = 'overview' | 'description' | 'channels' | 'board' | 'applications' | 'interviews' | 'promotion' | 'activity'

const TABS: { id: TabId; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'description', label: 'Description' },
  { id: 'channels', label: 'Channels' },
  { id: 'board', label: 'Board' },
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
  custom: Record<string, unknown> | null
  company: { name: string; short_code: string } | null
  hiring_manager_id: string | null
  hiring_manager: { full_name: string } | null
  skip_statuses: string[]
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
  sub_status_key: string | null
  in_play: boolean
  closed_at: string | null
  closed_reason: string | null
  received_at: string
  employment_period_id: string | null
  next_action: string | null
  next_action_due: string | null
  source_key: string | null
  source: { label: string } | null
  candidate: {
    id: string
    full_name: string
    email: string | null
    phone: string | null
    do_not_contact: boolean
    contact_again_after: string | null
  } | null
  owner: { full_name: string } | null
  employment_period: { person_id: string } | null
}

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const jobId = route.params.jobId as string

const job = ref<Job | null>(null)
const applications = ref<ApplicationRow[]>([])
const lookups = useHiringLookupsStore()
// The header numbers come from the database (opening_counts, 0097), not from
// the page of rows loaded below; `matching` is how many rows the filter finds.
const counts = ref({ in_play: 0, hired: 0, total: 0 })
const stageInPlay = ref<Record<string, number>>({})
const matching = ref(0)
const queueRows = ref<ApplicationRow[]>([])
const hiredRows = ref<ApplicationRow[]>([])
const loadingMore = ref(false)
const listLoading = ref(false)
const hasMore = computed(() => applications.value.length < matching.value)
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
const uploadCvsDialog = ref<InstanceType<typeof UploadCvsDialog> | null>(null)
const pickFromPoolDialog = ref<InstanceType<typeof PickFromPoolDialog> | null>(null)
const confirmHireDialog = ref<InstanceType<typeof AddEmployeeDialog> | null>(null)
const rejectDialog = ref<InstanceType<typeof RejectApplicationDialog> | null>(null)
const dialogs = useDialogStore()
const channelsPanel = ref<InstanceType<typeof JobChannelsPanel> | null>(null)
const activityPanel = ref<InstanceType<typeof JobActivityPanel> | null>(null)

// Statuses (plan 054, every stage since plan 068): the lookup, the newest
// event per application, the filters over the list, and the rows ticked for
// a bulk set.
const statusDialog = ref<InstanceType<typeof StatusDialog> | null>(null)
const subStatusRows = computed<SubStatusRow[]>(() => lookups.statuses)
const lastActivity = ref<Record<string, string>>({})
// The activity query came back at its cap, so rows missing from it may simply
// have been cut off — their activity is unknown (see loadLastActivity).
const activityTruncated = ref(false)
const ACTIVITY_CAP = 1000
const subStatusFilter = ref('')
const notRespondingOnly = ref(false)
const selectedIds = ref<string[]>([])
const outreachTarget = ref<ApplicationRow[]>([])

const activeTab = computed<TabId>(() => {
  const raw = route.query.tab
  const id = Array.isArray(raw) ? raw[0] : raw
  return TABS.some((t) => t.id === id) ? (id as TabId) : 'overview'
})

function selectTab(id: TabId): void {
  router.replace({ query: { tab: id } })
}

const canEdit = computed(() => (job.value ? auth.can(job.value.company_id, 'jobs.edit') : false))
// A hint only: the pool RPCs and RLS decide (plan 052).
const canSource = computed(() => auth.isAdmin || auth.canAnywhere('candidates.source'))
// A hint only: set_application_status decides (plan 068).
const canReview = computed(() => (job.value ? auth.can(job.value.company_id, 'candidates.review') : false))
const subStatusLabels = computed<Record<string, string>>(() => statusLabels(subStatusRows.value))
const subStatusGroups = computed(() => statusFilterGroups(subStatusRows.value))
// The status filter runs in the query (loadApplications); "not responding"
// is judged here over the rows loaded so far, from their last activity.
const visibleApplications = computed(() =>
  applications.value.filter((a) => !notRespondingOnly.value || isNotResponding(a)),
)
const selectedApplications = computed(() => applications.value.filter((a) => selectedIds.value.includes(a.id)))
const outreachApplications = computed<OutreachApplication[]>(() =>
  outreachTarget.value.map((a) => ({ id: a.id, full_name: a.candidate?.full_name ?? '—', stage_key: a.stage_key, sub_status_key: a.sub_status_key })),
)

/** D3 as the lib mirrors it: the newest event in the window, else received_at; the job must be live. */
function isNotResponding(a: ApplicationRow): boolean {
  const last = lastActivity.value[a.id] ?? null
  // A truncated activity result cannot tell "no event in the window" from "cut
  // off", so the received_at fallback would flag rows wrongly: unknown, not flagged.
  if (!last && activityTruncated.value) return false
  return notResponding(
    { stage_key: a.stage_key, sub_status_key: a.sub_status_key, in_play: a.in_play, last_activity_at: last, received_at: a.received_at, job_status: job.value?.status ?? '' },
    todayDb(),
  )
}

function toggleSelected(id: string, checked: boolean): void {
  selectedIds.value = checked ? [...new Set([...selectedIds.value, id])] : selectedIds.value.filter((x) => x !== id)
}

// Change a filter and the rows it hides leave the selection with them, so the
// dialog can never log an application the recruiter cannot see.
watch(notRespondingOnly, () => {
  const visible = new Set(visibleApplications.value.map((a) => a.id))
  selectedIds.value = selectedIds.value.filter((id) => visible.has(id))
})
watch(subStatusFilter, () => void loadList())

function openOutreach(rows: ApplicationRow[]): void {
  outreachTarget.value = rows
  statusDialog.value?.open()
}

async function onLogged(): Promise<void> {
  selectedIds.value = []
  await loadApplications()
}
// Candidates with an open application here — the pool picker's "In pipeline".
const inPipeline = computed(() =>
  applications.value.flatMap((a) => (a.candidate && a.in_play ? [a.candidate.id] : [])),
)
const hiredCount = computed(() => counts.value.hired)
const activeCount = computed(() => counts.value.in_play)
const actionQueue = computed(() => candidateQueue(queueRows.value))
const liveChannels = computed(() => channels.value.filter(isPublished).length)
// A draft role has nothing in it yet, and four tiles reading zero say so less
// clearly than the status card above them already does.
const hasNumbersWorthShowing = computed(
  () => liveChannels.value > 0 || activeCount.value > 0 || hiredCount.value > 0,
)

const step = computed(() =>
  currentStep({
    status: job.value?.status ?? 'draft',
    channels: channels.value,
    applications: counts.value.total,
    hired: hiredCount.value,
  }),
)

// The status picker (every other status, back or on) and what a filled job
// still has in play (plan 070: the job fills itself; the rest wait for HR).
const statusOptions = computed(() =>
  job.value
    ? jobStatusOptions({ status: job.value.status, hasDescription: (job.value.description ?? '').trim().length > 0 })
    : [],
)
const statusChoice = ref('')
const headcount = computed(() => (job.value ? jobHeadcount(job.value) : 1))
const atOfferCount = computed(() => stageInPlay.value.offer ?? 0)
const withdrawBusy = ref(false)

// The pipeline by stage counts who is still in play there (and every hire);
// the rest — rejected, withdrawn, closed with the job — are counted once, as finished.
const stageCounts = computed(() => {
  const counted = (s: StageKey) => (s === 'hired' ? counts.value.hired : (stageInPlay.value[s] ?? 0))
  const byStage = STAGES.map((s) => ({ key: s, label: STAGE_LABEL[s], count: counted(s) }))
  const finished = Math.max(0, counts.value.total - counts.value.in_play - counts.value.hired)
  return [...byStage, { key: 'finished', label: 'Finished', count: finished }].filter((c) => c.count > 0)
})
const inInterview = computed(() => stageCounts.value.find((c) => c.key === 'interview')?.count ?? 0)

function jobBadgeClass(status: string): string {
  if (status === 'open') return 'green'
  if (status === 'filled' || status === 'ready') return 'blue'
  if (status === 'on_hold') return 'amber'
  return ''
}

function stageBadgeClass(stage: string, inPlay = true): string {
  if (stage === 'hired') return 'green'
  if (!inPlay) return ''
  if (stage === 'offer') return 'amber'
  return 'blue'
}

/** "Job closed — <reason> (<date>)" on a row its job's closing marked; its status is then locked. */
function closureOf(a: ApplicationRow): string | null {
  return closureLine(a.closed_at, a.closed_reason)
}

async function loadJob(): Promise<void> {
  error.value = null
  const { data, error: err } = await supabase
    .from('jobs')
    .select(
      `id, title, description, description_revision, screening_questions, scorecard_criteria, status, company_id, custom, hiring_manager_id, skip_statuses,
       company:companies(name, short_code),
       hiring_manager:people!jobs_hiring_manager_id_fkey(full_name),
       request:hiring_requests(title, headcount, target_start_date,
         hiring_manager:people!hiring_requests_hiring_manager_id_fkey(full_name))`,
    )
    .eq('id', jobId)
    .maybeSingle()
  if (err || !data) {
    error.value = missingRecordMessage({
      noun: 'job',
      lookupFailed: Boolean(err),
      seesEverything: auth.isAdmin,
      plural: 'it',
    })
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

const APPLICATION_COLUMNS = `id, stage_key, sub_status_key, in_play, closed_at, closed_reason, received_at, employment_period_id, next_action, next_action_due, source_key,
       source:candidate_sources!applications_source_key_fkey(label),
       candidate:candidates(id, full_name, email, phone, do_not_contact, contact_again_after),
       owner:people!applications_owner_id_fkey(full_name),
       employment_period:employment_periods!applications_employment_period_id_fkey(person_id)`

/** One window of this job's applications; the status filter runs here, in the query. */
async function fetchApplicationPage(from: number) {
  let query = supabase.from('applications').select(APPLICATION_COLUMNS, { count: 'exact' }).eq('job_id', jobId)
  if (subStatusFilter.value) query = query.eq('sub_status_key', subStatusFilter.value)
  return orderNewestFirst(query).range(from, from + LIST_PAGE - 1)
}

// A newer list load (a filter change, an action) retires answers still on the way.
const listGate = createRequestGate()

/** Everything the page shows about applications: the list window, header counts, Overview lists. */
async function loadApplications(): Promise<void> {
  await Promise.all([loadList(), loadCounts(), loadOverviewLists()])
}

/** First window of the list again (after a filter or a change). */
async function loadList(): Promise<void> {
  const ticket = listGate.next()
  appError.value = null
  loadingMore.value = false
  listLoading.value = true
  const page = await fetchApplicationPage(0)
  if (!listGate.isCurrent(ticket)) return
  listLoading.value = false
  if (page.error) {
    appError.value = 'Could not load applications. Check your access and connection.'
    console.error('Applications load failed:', page.error.message)
    return
  }
  applications.value = (page.data ?? []) as unknown as ApplicationRow[]
  matching.value = page.count ?? applications.value.length
  // A row that is no longer on this job leaves the selection with it.
  selectedIds.value = selectedIds.value.filter((id) => applications.value.some((a) => a.id === id))
  lastActivity.value = {}
  activityTruncated.value = false
  await loadLastActivity(applications.value.map((a) => a.id), ticket)
}

async function loadMoreApplications(): Promise<void> {
  if (listLoading.value || loadingMore.value || !hasMore.value) return
  const ticket = listGate.snapshot()
  loadingMore.value = true
  appError.value = null
  const page = await fetchApplicationPage(applications.value.length)
  if (!listGate.isCurrent(ticket)) return
  loadingMore.value = false
  if (page.error) {
    appError.value = 'Could not load more applications. Check your connection and try again.'
    console.error('Applications load-more failed:', page.error.message)
    return
  }
  const rows = (page.data ?? []) as unknown as ApplicationRow[]
  applications.value = [...applications.value, ...rows]
  matching.value = page.count ?? matching.value
  await loadLastActivity(rows.map((a) => a.id), ticket)
}

/** Overview's action queue and hired list: their own bounded queries, not the paged list. */
async function loadOverviewLists(): Promise<void> {
  const [queue, hired] = await Promise.all([
    supabase
      .from('applications')
      .select(APPLICATION_COLUMNS)
      .eq('job_id', jobId)
      .eq('in_play', true)
      .order('next_action_due', { ascending: true, nullsFirst: false })
      .order('id')
      .limit(LIST_PAGE),
    supabase.from('applications').select(APPLICATION_COLUMNS).eq('job_id', jobId).eq('stage_key', 'hired').order('id').limit(LIST_PAGE),
  ])
  if (queue.error || hired.error) {
    console.error('Overview lists load failed:', (queue.error ?? hired.error)?.message)
    return
  }
  queueRows.value = (queue.data ?? []) as unknown as ApplicationRow[]
  hiredRows.value = (hired.data ?? []) as unknown as ApplicationRow[]
}

/** opening_counts for the header, and who is in play at each open stage (head-only counts). */
async function loadCounts(): Promise<void> {
  const openStages = STAGES.filter((s) => s !== 'hired')
  const [summary, ...perStage] = await Promise.all([
    supabase.rpc('opening_counts', { p_job_ids: [jobId] }),
    ...openStages.map((s) =>
      supabase.from('applications').select('id', { count: 'exact', head: true }).eq('job_id', jobId).eq('in_play', true).eq('stage_key', s),
    ),
  ])
  if (summary.error) {
    console.error('Opening counts load failed:', summary.error.message)
    return
  }
  const row = ((summary.data ?? []) as { in_play: number; hired: number; total: number }[])[0]
  counts.value = { in_play: row?.in_play ?? 0, hired: row?.hired ?? 0, total: row?.total ?? 0 }
  stageInPlay.value = Object.fromEntries(openStages.map((s, i) => [s, perStage[i].count ?? 0]))
}

/**
 * The newest application_event per application, for the "not responding"
 * badge (D3): the second round trip the plan allows. Keyed by the job
 * through the embed (no id list in the URL) and bounded to the last 30
 * days, so the rows stay few: an application with no event in the window
 * falls back to received_at, which gives D3's answer — its older events, if
 * any, never postdate its receipt.
 *
 * Asked for the ids just loaded (a window of 50), newest first and capped at 1,000 rows: a full page means the
 * result may be a prefix, and the fallback above stops applying (isNotResponding).
 */
async function loadLastActivity(ids: string[], ticket: number): Promise<void> {
  if (!ids.length) return
  const since = new Date(`${todayDb()}T00:00:00Z`)
  since.setUTCDate(since.getUTCDate() - NOT_RESPONDING_DAYS)
  const { data, error: err } = await supabase
    .from('application_events')
    .select('application_id, created_at')
    .in('application_id', ids)
    .gte('created_at', since.toISOString())
    .order('created_at', { ascending: false })
    .limit(ACTIVITY_CAP)
  if (!listGate.isCurrent(ticket)) return
  if (err) {
    console.error('Application activity load failed:', err.message)
    return
  }
  activityTruncated.value = activityTruncated.value || (data ?? []).length === ACTIVITY_CAP
  const newest = new Map<string, string>(Object.entries(lastActivity.value))
  for (const e of data ?? []) {
    const prev = newest.get(e.application_id)
    if (!prev || prev < e.created_at) newest.set(e.application_id, e.created_at)
  }
  lastActivity.value = Object.fromEntries(newest)
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
  const { data, error: err } = await supabase
    .from('jobs')
    .update({
      description: descriptionDraft.value,
      screening_questions: parsed.data,
      scorecard_criteria: criteria.data,
      description_revision: revision,
    })
    .eq('id', job.value.id)
    .select('id')
    .maybeSingle()
  descSaving.value = false
  // Zero rows back means RLS refused the write (a grant revoked since the page loaded).
  if (err || !data) {
    descError.value = friendlyJobsError(err?.message ?? 'row-level security')
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

async function applyStatus(): Promise<void> {
  const to = statusChoice.value
  if (!to) return
  await setStatus(to)
  if (!statusError.value) statusChoice.value = ''
}

/**
 * Everyone still in play on a filled job, closed at once (withdraw_in_play,
 * 0096): each keeps their status and gets the closure mark "Position
 * filled.". Asked first, naming how many and how many have an offer out.
 */
async function withdrawRest(): Promise<void> {
  if (!job.value) return
  const n = activeCount.value
  const offers = atOfferCount.value
  const ok = await dialogs.confirmAction({
    title: `Withdraw the ${n} ${n === 1 ? 'candidate' : 'candidates'} still in play?`,
    hint: `They keep their status and are marked Job closed, with the reason "Position filled."${offers ? ` ${offers} of them ${offers === 1 ? 'has' : 'have'} an offer out.` : ''} The hires stay as they are.`,
    confirmLabel: 'Withdraw them',
    danger: true,
  })
  if (!ok) return
  actionError.value = null
  withdrawBusy.value = true
  const { error: err } = await supabase.rpc('withdraw_in_play', { p_job_id: job.value.id })
  withdrawBusy.value = false
  if (err) {
    actionError.value = friendlyCandidatesError(err.message)
    return
  }
  await loadApplications()
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

async function deleteApplication(app: ApplicationRow): Promise<void> {
  if (!canReview.value || busyId.value) return
  busyId.value = app.id
  actionError.value = null
  try {
    const confirmed = await dialogs.confirmAction({
      title: `Delete ${app.candidate?.full_name ?? 'this candidate'}'s application?`,
      hint: `This permanently removes their application and its notes and stage history from ${job.value?.title ?? 'this job'}. Their candidate profile, other applications and any employee record will remain. This cannot be undone.`,
      confirmLabel: 'Delete application',
      danger: true,
    })
    if (!confirmed) return
    const { error: err } = await supabase.rpc('delete_job_application', { p_application_id: app.id })
    if (err) {
      actionError.value = friendlyDetachError(err.message)
      return
    }
    selectedIds.value = selectedIds.value.filter((id) => id !== app.id)
    await loadApplications()
  } catch {
    actionError.value = 'Could not confirm deletion. Refresh the page before trying again.'
  } finally {
    busyId.value = null
  }
}

/** A quick move (plan 075): the stage's first open status, through the one door. */
async function moveTo(app: ApplicationRow, stageKey: StageKey): Promise<void> {
  actionError.value = null
  const target = firstOpenStatus(subStatusRows.value, stageKey)
  if (!target) {
    actionError.value = noStatusesHint(STAGE_LABEL[stageKey])
    return
  }
  busyId.value = app.id
  const result = await setApplicationStatus([app.id], target.key)
  busyId.value = null
  if (result.error) {
    actionError.value = result.error
    return
  }
  await loadApplications()
}

// The same dialog as the application page: a Rejected status, set through the one door.
function reject(app: ApplicationRow): void {
  rejectDialog.value?.open('reject', app.candidate?.full_name ?? '', [app.id], app.stage_key)
}

function openConfirmHire(app: ApplicationRow): void {
  if (!job.value) return
  void confirmHireDialog.value?.open({
    applicationId: app.id,
    candidateName: app.candidate?.full_name ?? '',
    candidateEmail: app.candidate?.email ?? null,
    candidatePhone: app.candidate?.phone ?? null,
    jobTitle: job.value.title,
    companyId: job.value.company_id,
  })
}

async function onHired(): Promise<void> {
  await Promise.all([loadApplications(), loadJob()])
}

/**
 * Delete the job itself, once its applicant list is empty (plan 064).
 *
 * The database is the rule — `applications.job_id` is NO ACTION, so a job
 * anybody applied to cannot go — and the button says the count rather than
 * simply refusing, because the way out is the Delete on each row above.
 */
async function removeJob(): Promise<void> {
  if (!job.value || counts.value.total > 0) return
  const ok = await dialogs.confirmAction({
    title: `Delete ${job.value.title}?`,
    hint: 'Its applicant list is empty, so nothing is lost. This cannot be undone — close it instead if you only want it out of the way.',
    confirmLabel: 'Delete job',
    danger: true,
  })
  if (!ok) return
  statusError.value = null
  statusBusy.value = true
  const { data, error: err } = await supabase.from('jobs').delete().eq('id', job.value.id).select('id')
  statusBusy.value = false
  if (err) {
    statusError.value = friendlyJobsError(err.message)
    return
  }
  // A row the policies filtered away comes back with no error and no rows.
  if (!data?.length) {
    statusError.value = 'That job was not deleted — you may not have permission to.'
    return
  }
  void router.push({ name: 'hiring', query: { tab: 'openings' } })
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
  if (job.value) await Promise.all([loadApplications(), loadChannels(), lookups.ensure()])
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
          <span v-if="tab.id === 'applications' && counts.total" class="count">{{ counts.total }}</span>
        </button>
      </div>

      <section v-if="activeTab === 'overview'" class="card journey-focus" aria-label="Role next step">
        <div>
          <div class="eyebrow">Next action</div>
          <h2>{{ appError ? 'Candidate status unavailable' : actionQueue.length ? 'Keep candidates moving' : hiredCount ? 'Continue the hiring handoff' : job.status === 'draft' ? 'Prepare this role' : 'Find your next colleague' }}</h2>
          <p>{{ appError ? 'Reload the page to check candidate progress.' : actionQueue.length ? `${actionQueue.length} active candidates. Review due actions and assign an owner to each candidate.` : hiredCount ? 'Open a hired candidate to continue to their employee record and onboarding.' : job.status === 'draft' ? 'Complete the description, then mark the role ready from Overview.' : 'Review your channels or add candidates directly to the role.' }}</p>
          <p v-if="['on_hold', 'closed', 'filled'].includes(job.status)">This role is {{ job.status.replace('_', ' ') }}. Review its status before starting new recruitment activity.</p>
          <small><JobHiringManagerField
            :job-id="job.id"
            :company-id="job.company_id"
            :hiring-manager-id="job.hiring_manager_id"
            :hiring-manager-name="job.hiring_manager?.full_name ?? null"
            :can-edit="canEdit"
            @changed="loadJob"
          /><template v-if="job.request?.target_start_date"> &middot; Target start: {{ job.request.target_start_date }}</template></small>
        </div>
        <button class="button" type="button" @click="selectTab(actionQueue.length || hiredCount ? 'applications' : job.status === 'draft' ? 'description' : 'channels')">{{ actionQueue.length || hiredCount ? 'View candidates' : job.status === 'draft' ? 'Review description' : 'Review channels' }}</button>
      </section>

      <!-- Overview -->
      <div v-if="activeTab === 'overview'">
        <AfterFillCard v-if="job.status === 'filled'" :job-id="job.id" :can-review="canReview" @changed="loadApplications()" />
        <JobTeamCard :job-id="job.id" :can-edit="canEdit" />
        <section class="card journey-queue" aria-label="Candidate next actions">
          <div class="card-head"><div><h2>Candidate next actions</h2><p>Due dates first. Open a candidate to review, interview, or agree an offer.</p></div></div>
          <p v-if="appError" class="error-note" role="alert">{{ appError }}</p>
          <div v-else-if="!actionQueue.length" class="empty">No active candidates awaiting a next step.</div>
          <div v-for="a in actionQueue" v-else :key="a.id" class="journey-candidate">
            <div><router-link :to="{ name: 'application', params: { applicationId: a.id } }"><strong>{{ a.candidate?.full_name ?? 'Candidate' }}</strong></router-link>
              <p>{{ a.next_action || candidateNextStep(a.stage_key).title }}</p>
              <small>{{ a.owner?.full_name ?? 'Owner needed' }} &middot; {{ a.next_action_due ? `Due ${a.next_action_due}` : 'No due date set' }}</small>
            </div>
            <span class="badge" :class="stageBadgeClass(a.stage_key, a.in_play)">{{ stageName(a.stage_key) }}</span>
            <router-link class="button secondary small-btn" :to="{ name: 'application', params: { applicationId: a.id } }">{{ candidateNextStep(a.stage_key).label }}</router-link>
          </div>
        </section>
        <section v-if="hiredCount" class="card journey-queue" aria-label="Hired candidates">
          <div class="card-head"><div><h2>Hired &middot; continue to onboarding</h2><p>Review each new colleague's preparations and employee record.</p></div></div>
          <div v-for="a in hiredRows" :key="a.id" class="journey-candidate">
            <div><strong>{{ a.candidate?.full_name ?? 'New colleague' }}</strong><p>Hire confirmed</p></div>
            <router-link class="button secondary small-btn" :to="{ name: 'application', params: { applicationId: a.id } }">View onboarding handoff</router-link>
          </div>
        </section>
        <div v-if="hasNumbersWorthShowing" class="metrics">
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
            <span class="metric-value">{{ inInterview }}</span>
          </div>
          <div class="card metric-tile">
            <span class="metric-label">Hired</span>
            <span class="metric-value">{{ hiredCount }} / {{ headcount }}</span>
          </div>
        </div>

        <div class="card">
          <div class="card-head">
            <div>
              <h2>Status</h2>
              <p>A job opens when its listing goes live; it can pause or close without losing candidates.</p>
            </div>
            <div v-if="canEdit" class="row-actions">
              <select v-model="statusChoice" class="status-picker" :disabled="statusBusy" aria-label="Change status" data-testid="job-status-picker">
                <option value="">Change status…</option>
                <option v-for="o in statusOptions" :key="o.to" :value="o.to" :disabled="o.disabled">{{ o.label }}</option>
              </select>
              <button
                class="button secondary small-btn"
                type="button"
                :disabled="statusBusy || !statusChoice"
                data-testid="job-status-apply"
                @click="applyStatus"
              >
                {{ statusBusy ? 'Saving…' : 'Apply' }}
              </button>
              <button
                class="button secondary small-btn danger-text"
                type="button"
                :disabled="statusBusy || counts.total > 0"
                :title="counts.total > 0
                  ? `${counts.total} application${counts.total === 1 ? '' : 's'} on this job. Delete them first, from the list below.`
                  : 'Nothing was ever received for this job, so it can go.'"
                data-testid="job-delete"
                @click="removeJob"
              >
                Delete job
              </button>
            </div>
          </div>
          <p v-if="statusError" class="error-note" role="alert" style="margin: 16px 24px">{{ statusError }}</p>
          <div v-if="job.status === 'filled'" class="filled-note" data-testid="job-filled-note">
            <span>{{ filledNote(activeCount) }}</span>
            <button
              v-if="canReview && activeCount > 0"
              class="button secondary small-btn"
              type="button"
              :disabled="withdrawBusy"
              data-testid="job-withdraw-rest"
              @click="withdrawRest"
            >
              {{ withdrawBusy ? 'Withdrawing…' : 'Withdraw the rest' }}
            </button>
          </div>
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
                <template v-if="counts.total">
                  <span v-for="c in stageCounts" :key="c.key" class="stage-count">{{ c.label }} {{ c.count }}</span>
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
                <template v-else-if="job.status === 'filled'">Filled — withdraw the candidates still in play when you are ready.</template>
                <template v-else>Hired — the job fills itself once the headcount is met.</template>
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
      <JobPipelineBoard
        v-else-if="activeTab === 'board'"
        :job-id="job.id"
        :job-status="job.status"
        :skip-statuses="job.skip_statuses ?? []"
        :can-review="canReview"
        :can-edit="canEdit"
        @changed="loadJob(); loadApplications()"
      />
      <div v-else-if="activeTab === 'applications'" class="card applications-card">
        <div class="card-head">
          <div>
            <h2>Applications</h2>
            <p>Candidates moving through this job's pipeline.</p>
          </div>
          <div class="head-actions">
            <button v-if="canReview" class="button secondary" type="button" :disabled="!selectedApplications.length" data-testid="log-outreach" @click="openOutreach(selectedApplications)">
              Set status
            </button>
            <button v-if="canSource" class="button secondary" type="button" data-testid="source-from-pool" @click="pickFromPoolDialog?.open()">
              Source from pool
            </button>
            <button class="button secondary" type="button" @click="addCandidateDialog?.open()">
              Add candidate
            </button>
            <button class="button" type="button" @click="uploadCvsDialog?.open()">
              Upload CVs
            </button>
          </div>
        </div>
        <p v-if="appError" class="error-note" role="alert" style="margin: 16px 24px">{{ appError }}</p>
        <p v-if="actionError" class="error-note" role="alert" style="margin: 16px 24px">{{ actionError }}</p>
        <div v-if="!counts.total" class="empty">No candidates yet. Add one to start the pipeline.</div>
        <div v-else>
          <div class="filter-row">
            <label class="filter">
              <span>Status</span>
              <select v-model="subStatusFilter" data-testid="filter-sub-status">
                <option value="">Any status</option>
                <optgroup v-for="g in subStatusGroups" :key="g.stageKey" :label="g.stageLabel">
                  <option v-for="s in g.options" :key="s.key" :value="s.key">{{ s.label }}</option>
                </optgroup>
              </select>
            </label>
            <label class="filter check">
              <input v-model="notRespondingOnly" type="checkbox" data-testid="filter-not-responding" />
              <span>Not responding only (among loaded)</span>
            </label>
            <span v-if="selectedIds.length" class="selection-note" data-testid="selection-count">{{ selectedIds.length }} selected</span>
          </div>
          <div v-if="!visibleApplications.length" class="empty">No applications match these filters.</div>
          <div v-for="a in visibleApplications" :key="a.id" class="application-row">
            <input
              v-if="canReview"
              class="select-app"
              type="checkbox"
              :disabled="Boolean(closureOf(a)) || a.stage_key === 'hired'"
              :checked="selectedIds.includes(a.id)"
              :aria-label="`Select ${a.candidate?.full_name ?? 'application'}`"
              :data-testid="`select-app-${a.id}`"
              @change="toggleSelected(a.id, ($event.target as HTMLInputElement).checked)"
            />
            <div class="row-text">
              <router-link
                class="candidate-link"
                :to="canSource && a.candidate ? { name: 'candidate', params: { candidateId: a.candidate.id } } : { name: 'application', params: { applicationId: a.id } }"
              >
                <strong>{{ a.candidate?.full_name ?? '—' }}</strong>
              </router-link>
              <small>
                {{ a.candidate?.email ?? '—' }}
                <template v-if="a.source"> · via {{ a.source.label }}</template>
                <template v-if="a.owner"> · {{ a.owner.full_name }}</template>
                <template v-if="a.next_action"> · next: {{ a.next_action }}<template v-if="a.next_action_due"> by {{ a.next_action_due }}</template></template>
              </small>
            </div>
            <span v-if="a.candidate?.do_not_contact" class="badge amber">Do not contact</span>
            <span class="badge" :class="stageBadgeClass(a.stage_key, a.in_play)">{{ stageName(a.stage_key) }}</span>
            <!-- Not a .badge: the E2E rows locate the stage badge by that class alone. -->
            <span v-if="closureOf(a)" class="sub-badge" data-testid="closure-badge">{{ closureOf(a) }}</span>
            <span v-else-if="a.sub_status_key && subStatusLabels[a.sub_status_key]" class="sub-badge" data-testid="sub-badge">{{ subStatusLabels[a.sub_status_key] }}</span>
            <span v-if="isNotResponding(a)" class="sub-badge amber" data-testid="not-responding-badge">Not responding</span>
            <div class="row-actions">
              <button
                v-if="canReview"
                class="button secondary small-btn delete-application"
                type="button"
                :disabled="busyId !== null"
                :aria-label="`Delete application for ${a.candidate?.full_name ?? 'this candidate'}`"
                :data-testid="`delete-application-${a.id}`"
                @click="deleteApplication(a)"
              >Delete application</button>
              <button
                v-if="canReview"
                class="button secondary small-btn"
                type="button"
                :disabled="Boolean(closureOf(a)) || a.stage_key === 'hired'"
                :title="closureOf(a) ? 'Reopen the job to set a status.' : undefined"
                :data-testid="`log-outreach-${a.id}`"
                @click="openOutreach([a])"
              >
                Set status
              </button>
              <router-link
                v-if="a.stage_key === 'hired' && a.employment_period?.person_id"
                class="button secondary small-btn"
                :to="{ name: 'person', params: { personId: a.employment_period.person_id } }"
              >
                Open employee profile
              </router-link>
              <template v-else-if="a.in_play">
                <button v-if="a.stage_key === 'screening'" class="button secondary small-btn" type="button" :disabled="busyId === a.id" @click="moveTo(a, 'interview')">
                  Move to interview
                </button>
                <button v-if="a.stage_key === 'interview'" class="button secondary small-btn" type="button" :disabled="busyId === a.id" @click="moveTo(a, 'offer')">
                  Prepare offer
                </button>
                <button v-if="a.stage_key === 'offer'" class="button secondary small-btn" type="button" :disabled="busyId === a.id" @click="openConfirmHire(a)">
                  Confirm hire
                </button>
                <button class="button secondary small-btn" type="button" :disabled="busyId === a.id" @click="reject(a)">
                  Reject
                </button>
              </template>
            </div>
          </div>
          <div v-if="hasMore" class="load-more">
            <span>Showing {{ applications.length }} of {{ matching }}</span>
            <button class="button secondary" type="button" :disabled="loadingMore || listLoading" data-testid="load-more-applications" @click="loadMoreApplications">
              {{ loadingMore ? 'Loading…' : 'Load more' }}
            </button>
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
    <UploadCvsDialog
      v-if="job"
      ref="uploadCvsDialog"
      :job-id="job.id"
      :company-id="job.company_id"
      @created="loadApplications"
    />
    <PickFromPoolDialog
      v-if="job"
      ref="pickFromPoolDialog"
      :job-id="job.id"
      :company-id="job.company_id"
      :job-title="job.title"
      :in-pipeline="inPipeline"
      @created="loadApplications"
    />
    <AddEmployeeDialog ref="confirmHireDialog" @created="onHired" />
    <RejectApplicationDialog ref="rejectDialog" :rows="subStatusRows" @decided="loadApplications" />
    <StatusDialog ref="statusDialog" :applications="outreachApplications" :rows="subStatusRows" @logged="onLogged" />
  </div>
</template>

<style scoped>
.delete-application { color: var(--red); }
.journey-focus { padding: 20px 24px; margin-bottom: 18px; display: flex; align-items: center; justify-content: space-between; gap: 18px; flex-wrap: wrap; }
.journey-focus h2 { margin: 5px 0; }
.journey-focus p, .journey-candidate p { margin: 6px 0; font-size: 12px; }
.journey-focus small, .journey-candidate small { color: var(--muted); }
.journey-queue { margin-bottom: 18px; }
.journey-candidate { padding: 16px 24px; border-top: 1px solid var(--line); display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
.journey-candidate > div { flex: 1; min-width: 180px; }
.journey-candidate a { color: var(--ink); }

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
  font-size: 11px;
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
.status-picker { border: 1px solid var(--line); background: #fff; padding: 7px 10px; font-size: 12px; color: var(--ink); max-width: 100%; }
.filled-note { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; margin: 16px 24px 0; padding: 10px 14px; border-radius: 9px; background: #eef3f8; font-size: 12px; }
.detail-grid dt { font-size: 11px; color: var(--muted); margin-bottom: 6px; }
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
.load-more {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
  padding: 16px 24px;
  color: var(--muted, #667085);
}
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
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.candidate-link { text-decoration: none; color: inherit; }
.candidate-link:hover strong { color: var(--green); text-decoration: underline; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.head-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.filter-row { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; padding: 12px 24px; border-top: 1px solid #edf0eb; background: #fafbf9; }
.filter { display: flex; align-items: center; gap: 8px; font-size: 11px; color: var(--muted); }
.filter select { border: 1px solid var(--line); background: #fff; padding: 7px 10px; font-size: 12px; color: var(--ink); }
.filter.check { cursor: pointer; }
.selection-note { margin-left: auto; font-size: 11px; color: var(--muted); }
.select-app { width: 15px; height: 15px; margin: 0; flex-shrink: 0; accent-color: var(--green); }
.sub-badge { display: inline-flex; align-items: center; padding: 3px 9px; border-radius: 999px; font-size: 11px; font-weight: 550; background: #f0f1ef; color: var(--muted); white-space: nowrap; }
.sub-badge.amber { background: #fbf1da; color: var(--amber); }
</style>
