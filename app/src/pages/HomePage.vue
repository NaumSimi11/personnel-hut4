<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import type { RouteLocationRaw } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import {
  compensationToRows,
  documentReviewsToRows,
  itRequestsToRows,
  myRequestsToRows,
  payrollToRows,
  leaveToRows,
  type LeaveQueueRow,
  hiringManagerToRows,
  type HiringManagerRow,
  policiesToRows,
  type AckLite,
  type CompensationQueueRow,
  type DocumentReviewRow,
  type ItQueueRow,
  type MyRequestRow,
  type PayrollQueueRow,
  type PolicyQueueRow,
} from '@/lib/homeQueue'
import { todayDb } from '@/lib/compensation'
import {
  EMPTY_SNAPSHOT,
  awayToday,
  dashboardSections,
  statTiles,
  type ApplicationLite,
  type AwayRow,
  type DashboardSnapshot,
  type JobLite,
} from '@/lib/dashboard'
import DashboardStats from '@/components/home/DashboardStats.vue'
import RecruitmentSnapshot from '@/components/home/RecruitmentSnapshot.vue'
import CelebratePanel from '@/components/home/CelebratePanel.vue'
import AwayToday from '@/components/home/AwayToday.vue'

/**
 * Home (blueprint §7.1, plan 044): headline numbers by what the viewer may
 * see, the merged queue of what needs a decision, the recruitment snapshot
 * for people who see jobs, the celebrate block for everyone, then the
 * signed-in person's own open tasks.
 */

type PlanTaskLite = { id: string; critical: boolean; status: string }

type HiringRequestRow = {
  id: string
  title: string
  company: { name: string } | null
  requester: { full_name: string } | null
}

type OfferRow = {
  id: string
  candidate: { full_name: string } | null
  job: { id: string; title: string; company: { name: string } | null } | null
}

type OnboardingGapRow = {
  id: string
  start_date: string
  person: { full_name: string } | null
  company: { name: string } | null
  plan_tasks: PlanTaskLite[]
}

type MyTaskRow = {
  id: string
  title: string
  due_date: string | null
  plan_id: string
}

type QueueRow = {
  id: string
  title: string
  sub: string
  actionLabel: string
  to: RouteLocationRaw
}

const auth = useAuthStore()

const loading = ref(true)
const error = ref<string | null>(null)

const metrics = ref({
  hiringRequests: 0,
  openOnboardingTasks: 0,
})
const snapshot = ref<DashboardSnapshot>(EMPTY_SNAPSHOT)
const applications = ref<ApplicationLite[]>([])
const jobs = ref<JobLite[]>([])
const away = ref<AwayRow[]>([])

const queueRows = ref<QueueRow[]>([])
const myTasks = ref<MyTaskRow[]>([])

const firstName = computed(() => auth.personName?.split(' ')[0] ?? 'there')
// Read lazily: the person id lands with the profile, the queue is built on load.
const viewer = {
  get personId() {
    return auth.personId
  },
  can: (companyId: string, cap: string) => auth.can(companyId, cap),
}
const queueBadgeClass = computed(() => (queueRows.value.length > 0 ? 'amber' : 'green'))
const sections = computed(() => dashboardSections(auth))
// The database's today (UTC), the same day the facts below are computed for.
const todayLabel = new Date(`${todayDb()}T00:00:00Z`).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' })

/** The tiles the prototype showed per role, decided here by what the viewer already sees. */
const tiles = computed(() =>
  statTiles({
    snapshot: snapshot.value,
    away: away.value,
    applications: applications.value,
    requestsToDecide: metrics.value.hiringRequests,
    viewer: auth,
  }),
)

function criticalOpenCount(tasks: PlanTaskLite[]): number {
  return tasks.filter((t) => t.critical && t.status !== 'done' && t.status !== 'skipped').length
}

function hiringRequestsToRows(rows: HiringRequestRow[]): QueueRow[] {
  return rows.map((r) => ({
    id: `hiring-${r.id}`,
    title: r.title,
    sub: `${r.company?.name ?? '—'} · Hiring request${
      r.requester?.full_name ? ` by ${r.requester.full_name}` : ''
    }`,
    actionLabel: 'Review request',
    to: { name: 'hiring' },
  }))
}

function offersToRows(rows: OfferRow[]): QueueRow[] {
  return rows
    .filter((o) => o.job !== null)
    .map((o) => ({
      id: `offer-${o.id}`,
      title: `Offer: ${o.candidate?.full_name ?? '—'}`,
      sub: `${o.job?.company?.name ?? '—'} · ${o.job?.title ?? '—'} · awaiting hire confirmation`,
      actionLabel: 'Open job',
      to: { name: 'job', params: { jobId: o.job!.id } },
    }))
}

function onboardingGapsToRows(rows: OnboardingGapRow[]): QueueRow[] {
  return rows
    .map((p) => ({ p, criticalOpen: criticalOpenCount(p.plan_tasks) }))
    .filter(({ criticalOpen }) => criticalOpen > 0)
    .map(({ p, criticalOpen }) => ({
      id: `onboarding-${p.id}`,
      title: `Onboarding: ${p.person?.full_name ?? '—'}`,
      sub: `${p.company?.name ?? '—'} · ${criticalOpen} critical task${
        criticalOpen === 1 ? '' : 's'
      } before ${p.start_date}`,
      actionLabel: 'Open plan',
      to: { name: 'onboarding-plan', params: { planId: p.id } },
    }))
}

async function loadMyTasks(): Promise<{
  data: MyTaskRow[] | null
  error: { message: string } | null
}> {
  if (!auth.personId) return { data: [], error: null }
  return supabase
    .from('plan_tasks')
    .select('id, title, due_date, plan_id')
    .eq('owner_id', auth.personId)
    .eq('status', 'open')
    .order('due_date', { ascending: true })
}

/** The modules that arrived later (plan 034): what each viewer can read is RLS's call; what they can act on is the converters'. */
function loadLaterQueues() {
  const me = auth.personId ?? ''
  return Promise.all([
    supabase
      .from('compensation_records')
      .select('id, proposed_by, period:employment_periods(person_id, company_id, person:people!employment_periods_person_id_fkey(full_name), company:companies(name))')
      .eq('status', 'proposed'),
    supabase
      .from('document_requests')
      .select('id, person_id, company_id, category_key, person:people!document_requests_person_id_fkey(full_name), category:document_categories(label)')
      .eq('status', 'submitted'),
    me
      ? supabase
          .from('document_requests')
          .select('id, due_date, category:document_categories(label), company:companies(name)')
          .eq('person_id', me)
          .in('status', ['pending', 'needs_correction'])
      : Promise.resolve({ data: [], error: null }),
    supabase.from('policies').select('id, title, version, company:companies(name)').eq('status', 'published'),
    me ? supabase.from('policy_acknowledgements').select('policy_id, version').eq('person_id', me) : Promise.resolve({ data: [], error: null }),
    supabase
      .from('it_requests')
      .select('id, title, status, company_id, assignee_id, person:people!it_requests_person_id_fkey(full_name), company:companies(name)')
      .in('status', ['open', 'in_progress', 'blocked']),
    supabase
      .from('payroll_periods')
      .select('id, company_id, period_start, period_end, currency, prepared_by, company:companies(name)')
      .eq('status', 'in_review'),
    supabase
      .from('leave_requests')
      .select(
        'id, person_id, company_id, leave_type_key, start_date, end_date, working_days, status, cancellation_requested_at, cancellation_declined_at, person:people!leave_requests_person_id_fkey(full_name), company:companies(name)',
      )
      .in('status', ['pending', 'approved'])
      .gte('end_date', todayDb()),
    me
      ? supabase
          .from('hiring_requests')
          .select('id, company_id, title, status, target_start_date, requester:people!hiring_requests_requested_by_fkey(full_name), company:companies(name), jobs:jobs!jobs_hiring_request_id_fkey(id, status)')
          .eq('hiring_manager_id', me)
          .in('status', ['submitted', 'changes_requested', 'approved'])
      : Promise.resolve({ data: [], error: null }),
  ])
}

async function loadSnapshot(): Promise<{ error: { message: string } | null }> {
  const { data, error: err } = await supabase.rpc('dashboard_snapshot', { p_days: 30 })
  if (err) return { error: err }
  snapshot.value = { ...EMPTY_SNAPSHOT, ...(data as Partial<DashboardSnapshot>) }
  return { error: null }
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null

  const [
    applicationsRes,
    jobsRes,
    hiringRequestsCount,
    openTasksCount,
    hiringRequestsRes,
    offersRes,
    onboardingGapsRes,
    myTasksRes,
    laterRes,
    snapshotRes,
    candidateAssignments,
  ] = await Promise.all([
    supabase
      .from('applications')
      .select('id, job_id, stage_key, received_at, candidate:candidates(full_name), job:jobs(title, company:companies(name))')
      .order('received_at', { ascending: false }),  // every application the viewer may see: the pipeline counts all of them
    supabase.from('jobs').select('id, title, status, company:companies(name), request:hiring_requests!jobs_hiring_request_id_fkey(headcount)').in('status', ['ready', 'open']),
    supabase
      .from('hiring_requests')
      .select('*', { count: 'exact', head: true })
      .eq('status', 'submitted'),
    supabase.from('plan_tasks').select('*', { count: 'exact', head: true }).eq('status', 'open'),
    supabase
      .from('hiring_requests')
      .select(
        `id, title,
         company:companies(name),
         requester:people!hiring_requests_requested_by_fkey(full_name)`,
      )
      .eq('status', 'submitted'),
    supabase
      .from('applications')
      .select(
        `id,
         candidate:candidates(full_name),
         job:jobs(id, title, company:companies(name))`,
      )
      .eq('stage_key', 'offer'),
    supabase
      .from('plans')
      .select(
        `id, start_date,
         person:people!plans_person_id_fkey(full_name),
         company:companies(name),
         plan_tasks(id, critical, status)`,
      )
      .eq('kind', 'onboarding')
      .eq('status', 'in_progress'),
    loadMyTasks(),
    loadLaterQueues(),
    loadSnapshot(),
    auth.personId ? supabase.from('applications').select('id, company_id, stage_key, next_action, next_action_due, candidate:candidates(full_name), job:jobs(title)')
      .eq('owner_id', auth.personId).in('stage_key', ['new', 'screening', 'interview', 'offer']).order('next_action_due', { ascending: true }) : Promise.resolve({ data: [], error: null }),
  ])
  const [compRes, docReviewRes, myReqRes, policyRes, ackRes, itRes, payrollRes, leaveRes, managerRes] = laterRes

  let hadError = false
  const logIfError = (label: string, err: { message: string } | null) => {
    if (!err) return
    hadError = true
    console.error(`Overview: ${label} failed:`, err.message)
  }

  logIfError('applications', applicationsRes.error)
  logIfError('open jobs', jobsRes.error)
  logIfError('team snapshot', snapshotRes.error)
  logIfError('hiring requests count', hiringRequestsCount.error)
  logIfError('open onboarding tasks count', openTasksCount.error)
  logIfError('hiring requests queue', hiringRequestsRes.error)
  logIfError('offers queue', offersRes.error)
  logIfError('onboarding gaps queue', onboardingGapsRes.error)
  logIfError('my tasks', myTasksRes.error)
  logIfError('candidate assignments', candidateAssignments.error)
  logIfError('compensation queue', compRes.error)
  logIfError('document reviews queue', docReviewRes.error)
  logIfError('my document requests', myReqRes.error)
  logIfError('policies queue', policyRes.error)
  logIfError('acknowledgements', ackRes.error)
  logIfError('IT requests queue', itRes.error)
  logIfError('payroll queue', payrollRes.error)
  logIfError('leave queue', leaveRes.error)
  logIfError('hiring manager queue', managerRes.error)

  metrics.value = {
    hiringRequests: hiringRequestsCount.count ?? 0,
    openOnboardingTasks: openTasksCount.count ?? 0,
  }
  applications.value = (applicationsRes.data ?? []) as unknown as ApplicationLite[]
  jobs.value = (jobsRes.data ?? []) as unknown as JobLite[]
  away.value = awayToday((leaveRes.data ?? []) as unknown as Parameters<typeof awayToday>[0], todayDb())

  queueRows.value = [
    ...(candidateAssignments.data ?? []).filter(a => auth.can(a.company_id, 'candidates.review')).map(a => ({
      id: `candidate-${a.id}`, title: `Candidate: ${a.candidate?.full_name ?? 'Candidate'}`,
      sub: `${a.job?.title ?? 'Role'} · ${a.next_action || 'Set next action'} · ${a.next_action_due ? `Due ${a.next_action_due}` : 'No due date set'}`,
      actionLabel: 'Open candidate', to: { name: 'application', params: { applicationId: a.id } },
    })),
    ...hiringRequestsToRows((hiringRequestsRes.data ?? []) as HiringRequestRow[]),
    ...offersToRows((offersRes.data ?? []) as OfferRow[]),
    ...onboardingGapsToRows((onboardingGapsRes.data ?? []) as OnboardingGapRow[]),
    ...compensationToRows((compRes.data ?? []) as unknown as CompensationQueueRow[], viewer),
    ...documentReviewsToRows((docReviewRes.data ?? []) as unknown as DocumentReviewRow[], viewer),
    ...myRequestsToRows((myReqRes.data ?? []) as unknown as MyRequestRow[]),
    ...policiesToRows((policyRes.data ?? []) as unknown as PolicyQueueRow[], (ackRes.data ?? []) as AckLite[]),
    ...itRequestsToRows((itRes.data ?? []) as unknown as ItQueueRow[], viewer),
    ...payrollToRows((payrollRes.data ?? []) as unknown as PayrollQueueRow[], viewer),
    ...leaveToRows((leaveRes.data ?? []) as unknown as LeaveQueueRow[], viewer),
    ...hiringManagerToRows((managerRes.data ?? []) as unknown as HiringManagerRow[], viewer),
  ]
  myTasks.value = (myTasksRes.data ?? []) as MyTaskRow[]

  error.value = hadError ? 'Could not load the overview.' : null
  loading.value = false
}

onMounted(load)
</script>

<template>
  <div>
    <div class="page-head">
      <div class="eyebrow">{{ todayLabel }}</div>
      <h1>Welcome, {{ firstName }}.</h1>
      <p class="page-sub">A clear view of the team — what needs you, who is where, and what is coming up.</p>
    </div>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>

    <DashboardStats :tiles="tiles" :loading="loading" />

    <div class="card queue-card">
      <div class="card-head">
        <div>
          <h2>Needs a decision</h2>
          <p>Approvals, decisions, reviews, uploads and handovers that wait on you — one queue.</p>
        </div>
        <span class="badge" :class="queueBadgeClass">{{ queueRows.length }} open</span>
      </div>
      <div v-if="loading" class="empty">Loading overview…</div>
      <div v-else-if="!queueRows.length" class="empty">Nothing needs a decision right now.</div>
      <div v-else>
        <div v-for="(row, i) in queueRows" :key="row.id" class="queue-row">
          <div class="row-index">{{ String(i + 1).padStart(2, '0') }}</div>
          <div class="row-text">
            <strong>{{ row.title }}</strong>
            <small>{{ row.sub }}</small>
          </div>
          <div class="row-actions">
            <router-link class="button secondary small-btn" :to="row.to">
              {{ row.actionLabel }}
            </router-link>
          </div>
        </div>
      </div>
    </div>

    <RecruitmentSnapshot
      v-if="sections.recruitment"
      :applications="applications"
      :jobs="jobs"
      :show-pipeline="sections.pipeline"
      :show-openings="sections.openings"
      :loading="loading"
    />

    <CelebratePanel :snapshot="snapshot" :show-team="sections.team" :loading="loading" @changed="loadSnapshot">
      <template #aside>
        <AwayToday v-if="sections.away" :rows="away" :loading="loading" />
      </template>
    </CelebratePanel>

    <div class="card tasks-card">
      <div class="card-head">
        <div>
          <h2>My tasks</h2>
          <p>Onboarding tasks assigned to you that are still open.</p>
        </div>
      </div>
      <div v-if="loading" class="empty">Loading your tasks…</div>
      <div v-else-if="!myTasks.length" class="empty">No tasks assigned to you.</div>
      <div v-else>
        <div v-for="t in myTasks" :key="t.id" class="queue-row">
          <div class="row-text">
            <strong>{{ t.title }}</strong>
            <small v-if="t.due_date">Due {{ t.due_date }}</small>
          </div>
          <div class="row-actions">
            <router-link
              class="button secondary small-btn"
              :to="{ name: 'onboarding-plan', params: { planId: t.plan_id } }"
            >
              Open plan
            </router-link>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.page-head { margin-bottom: 22px; }
.page-sub { margin: 0; font-size: 12px; color: var(--muted); }
.queue-card { margin-bottom: 22px; }
.queue-row {
  display: flex;
  align-items: center;
  gap: 13px;
  padding: 15px 24px;
  border-top: 1px solid #edf0eb;
  flex-wrap: wrap;
}
.row-index { font-size: 11px; font-weight: 650; color: var(--muted); width: 20px; flex-shrink: 0; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
