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
  policiesToRows,
  type AckLite,
  type CompensationQueueRow,
  type DocumentReviewRow,
  type ItQueueRow,
  type MyRequestRow,
  type PayrollQueueRow,
  type PolicyQueueRow,
} from '@/lib/homeQueue'

/**
 * Overview: the post-login "what needs me" screen (blueprint §7.1). Four
 * headline metrics, then one merged queue of pending handoffs across hiring
 * and onboarding, then the signed-in person's own open tasks.
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
  people: 0,
  companies: 0,
  hiringRequests: 0,
  openOnboardingTasks: 0,
})

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
  ])
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null

  const [
    peopleCount,
    companiesCount,
    hiringRequestsCount,
    openTasksCount,
    hiringRequestsRes,
    offersRes,
    onboardingGapsRes,
    myTasksRes,
    laterRes,
  ] = await Promise.all([
    supabase.from('people').select('*', { count: 'exact', head: true }).is('archived_at', null),
    supabase.from('companies').select('*', { count: 'exact', head: true }).is('archived_at', null),
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
  ])
  const [compRes, docReviewRes, myReqRes, policyRes, ackRes, itRes, payrollRes] = laterRes

  let hadError = false
  const logIfError = (label: string, err: { message: string } | null) => {
    if (!err) return
    hadError = true
    console.error(`Overview: ${label} failed:`, err.message)
  }

  logIfError('people count', peopleCount.error)
  logIfError('companies count', companiesCount.error)
  logIfError('hiring requests count', hiringRequestsCount.error)
  logIfError('open onboarding tasks count', openTasksCount.error)
  logIfError('hiring requests queue', hiringRequestsRes.error)
  logIfError('offers queue', offersRes.error)
  logIfError('onboarding gaps queue', onboardingGapsRes.error)
  logIfError('my tasks', myTasksRes.error)
  logIfError('compensation queue', compRes.error)
  logIfError('document reviews queue', docReviewRes.error)
  logIfError('my document requests', myReqRes.error)
  logIfError('policies queue', policyRes.error)
  logIfError('acknowledgements', ackRes.error)
  logIfError('IT requests queue', itRes.error)
  logIfError('payroll queue', payrollRes.error)

  metrics.value = {
    people: peopleCount.count ?? 0,
    companies: companiesCount.count ?? 0,
    hiringRequests: hiringRequestsCount.count ?? 0,
    openOnboardingTasks: openTasksCount.count ?? 0,
  }

  queueRows.value = [
    ...hiringRequestsToRows((hiringRequestsRes.data ?? []) as HiringRequestRow[]),
    ...offersToRows((offersRes.data ?? []) as OfferRow[]),
    ...onboardingGapsToRows((onboardingGapsRes.data ?? []) as OnboardingGapRow[]),
    ...compensationToRows((compRes.data ?? []) as unknown as CompensationQueueRow[], viewer),
    ...documentReviewsToRows((docReviewRes.data ?? []) as unknown as DocumentReviewRow[], viewer),
    ...myRequestsToRows((myReqRes.data ?? []) as unknown as MyRequestRow[]),
    ...policiesToRows((policyRes.data ?? []) as unknown as PolicyQueueRow[], (ackRes.data ?? []) as AckLite[]),
    ...itRequestsToRows((itRes.data ?? []) as unknown as ItQueueRow[], viewer),
    ...payrollToRows((payrollRes.data ?? []) as unknown as PayrollQueueRow[], viewer),
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
      <div class="eyebrow">Your people, connected</div>
      <h1>Welcome, {{ firstName }}.</h1>
      <p class="page-sub">People, hiring decisions, and the next step that needs an owner.</p>
    </div>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>

    <div class="metrics">
      <div class="card metric-tile">
        <span class="metric-label">People</span>
        <span class="metric-value">{{ metrics.people }}</span>
      </div>
      <div class="card metric-tile">
        <span class="metric-label">Companies</span>
        <span class="metric-value">{{ metrics.companies }}</span>
      </div>
      <div class="card metric-tile">
        <span class="metric-label">Hiring requests</span>
        <span class="metric-value">{{ metrics.hiringRequests }}</span>
      </div>
      <div class="card metric-tile">
        <span class="metric-label">Open onboarding tasks</span>
        <span class="metric-value">{{ metrics.openOnboardingTasks }}</span>
      </div>
    </div>

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
.metrics {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 14px;
  margin-bottom: 22px;
}
@media (max-width: 900px) {
  .metrics { grid-template-columns: repeat(2, 1fr); }
}
.metric-tile { display: flex; flex-direction: column; gap: 8px; padding: 18px 20px; }
.metric-label { font-size: 11px; color: var(--muted); font-weight: 550; }
.metric-value { font-size: 26px; font-weight: 750; letter-spacing: -0.02em; }
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
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
