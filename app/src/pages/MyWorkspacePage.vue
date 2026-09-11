<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { departureState } from '@/lib/departure'
import CompensationCard from '@/components/CompensationCard.vue'
import DocumentsCard from '@/components/DocumentsCard.vue'
import MyRequestsCard from '@/components/MyRequestsCard.vue'
import MyPoliciesCard from '@/components/MyPoliciesCard.vue'

/**
 * My workspace: the signed-in person's own record — their profile, their
 * onboarding plan (if any) and open tasks, their per-company access, and
 * their synced project assignments. Self-access is already covered by RLS
 * (the `app.is_self(...)` branches), so this page needs no capability at
 * all: it's what "you" can see about yourself.
 */

type Employment = {
  id: string
  company_id: string
  job_title: string
  status: string
  start_date: string
  end_date: string | null
  employment_type_key: string | null
  company: { name: string } | null
}

type MyPlanTask = {
  id: string
  title: string
  owner_role: string
  due_date: string | null
  critical: boolean
  status: string
  sort_order: number
}

type MyPlan = {
  id: string
  start_date: string
  plan_tasks: MyPlanTask[]
}

type MyTaskRow = {
  id: string
  title: string
  due_date: string | null
  plan_id: string
}

type Grant = {
  company_id: string
  company: { name: string } | null
  grant_capabilities: { capability_key: string }[]
}

type Capability = { key: string; label: string }

type MyProjectRow = {
  id: string
  project: {
    id: string
    name: string
    status: string | null
    source: string
    last_synced_at: string
  } | null
}

const auth = useAuthStore()

const person = ref<{ full_name: string; work_email: string | null } | null>(null)
const employments = ref<Employment[]>([])
const plan = ref<MyPlan | null>(null)
const myTasks = ref<MyTaskRow[]>([])
const grants = ref<Grant[]>([])
const myCompanies = computed(() => {
  const seen = new Map<string, { id: string; name: string }>()
  for (const e of employments.value) if (!seen.has(e.company_id)) seen.set(e.company_id, { id: e.company_id, name: e.company?.name ?? '' })
  return [...seen.values()]
})
const capabilities = ref<Capability[]>([])
const projects = ref<MyProjectRow[]>([])

const loading = ref(true)
const error = ref<string | null>(null)
const taskError = ref<string | null>(null)
const busyId = ref<string | null>(null)

const firstName = computed(() => auth.personName?.split(' ')[0] ?? 'there')
// A scheduled departure keeps the person current until they are marked former.
const current = computed(() => employments.value.find((e) => departureState(e) !== 'former') ?? null)

const criticalOpen = computed(() => {
  if (!plan.value) return 0
  return plan.value.plan_tasks.filter(
    (t) => t.critical && t.status !== 'done' && t.status !== 'skipped',
  ).length
})
const readinessBadgeClass = computed(() => (criticalOpen.value ? 'amber' : 'green'))
const readinessLabel = computed(() =>
  criticalOpen.value ? `${criticalOpen.value} readiness gaps` : 'Ready for day one',
)

const capabilityLabels = computed(() => new Map(capabilities.value.map((c) => [c.key, c.label])))

function employmentBadgeClass(status: string): string {
  if (status === 'active') return 'green'
  if (status === 'former') return ''
  return 'blue'
}

function taskStatusBadgeClass(status: string): string {
  if (status === 'done') return 'green'
  if (status === 'blocked') return 'amber'
  if (status === 'open') return 'blue'
  return ''
}

function labelsFor(grant: Grant): string[] {
  return grant.grant_capabilities
    .map((gc) => capabilityLabels.value.get(gc.capability_key) ?? gc.capability_key)
    .sort((a, b) => a.localeCompare(b))
}

function formatSync(at: string): string {
  return new Date(at).toLocaleString()
}

function friendlyTaskError(message: string): string {
  if (/row-level security/i.test(message) || /permission/i.test(message)) {
    return 'You do not have permission to change this task.'
  }
  return message
}

function fetchMyTasks() {
  return supabase
    .from('plan_tasks')
    .select('id, title, due_date, plan_id')
    .eq('owner_id', auth.personId as string)
    .eq('status', 'open')
    .order('due_date', { ascending: true })
}

async function markComplete(task: MyTaskRow): Promise<void> {
  taskError.value = null
  busyId.value = task.id
  const { error: err } = await supabase
    .from('plan_tasks')
    .update({ status: 'done', done_by: auth.personId, done_at: new Date().toISOString() })
    .eq('id', task.id)
  busyId.value = null
  if (err) {
    taskError.value = friendlyTaskError(err.message)
    return
  }
  const { data, error: reloadErr } = await fetchMyTasks()
  if (reloadErr) {
    console.error('My workspace: my tasks reload failed:', reloadErr.message)
    return
  }
  myTasks.value = (data ?? []) as MyTaskRow[]
}

async function load(): Promise<void> {
  const personId = auth.personId
  if (!personId) return
  loading.value = true
  error.value = null

  const [personRes, empRes, planRes, tasksRes, grantRes, capRes, projRes] = await Promise.all([
    supabase.from('people').select('full_name, work_email').eq('id', personId).maybeSingle(),
    supabase
      .from('employment_periods')
      .select(
        'id, company_id, job_title, status, start_date, end_date, employment_type_key, company:companies(name)',
      )
      .eq('person_id', personId)
      .order('start_date', { ascending: false }),
    supabase
      .from('plans')
      .select('id, start_date, plan_tasks(id, title, owner_role, due_date, critical, status, sort_order)')
      .eq('person_id', personId)
      .eq('kind', 'onboarding')
      .order('start_date', { ascending: false })
      .order('sort_order', { referencedTable: 'plan_tasks', ascending: true })
      .limit(1)
      .maybeSingle(),
    fetchMyTasks(),
    supabase
      .from('access_grants')
      .select('company_id, company:companies(name), grant_capabilities(capability_key)')
      .eq('person_id', personId),
    supabase.from('capabilities').select('key, label'),
    supabase
      .from('external_project_members')
      .select(
        'id, project:external_projects!external_project_members_project_id_fkey(id, name, status, source:provider_key, last_synced_at)',
      )
      .eq('person_id', personId),
  ])

  let hadError = false
  const logIfError = (label: string, err: { message: string } | null) => {
    if (!err) return
    hadError = true
    console.error(`My workspace: ${label} failed:`, err.message)
  }

  logIfError('profile', personRes.error)
  logIfError('employment history', empRes.error)
  logIfError('onboarding plan', planRes.error)
  logIfError('my tasks', tasksRes.error)
  logIfError('access grants', grantRes.error)
  logIfError('capabilities', capRes.error)
  logIfError('projects', projRes.error)

  person.value = personRes.data ?? null
  employments.value = (empRes.data ?? []) as Employment[]
  plan.value = (planRes.data ?? null) as MyPlan | null
  myTasks.value = (tasksRes.data ?? []) as MyTaskRow[]
  grants.value = (grantRes.data ?? []) as Grant[]
  capabilities.value = (capRes.data ?? []) as Capability[]
  projects.value = (projRes.data ?? []) as MyProjectRow[]

  error.value = hadError ? 'Could not load your workspace.' : null
  loading.value = false
}

onMounted(load)
</script>

<template>
  <div>
    <template v-if="!auth.personId">
      <div class="card">
        <div class="empty">
          Your sign-in is not linked to an employee record yet. Ask HR to connect it.
        </div>
      </div>
    </template>

    <template v-else>
      <div class="page-head">
        <div class="eyebrow">My workspace</div>
        <h1>Welcome, {{ firstName }}.</h1>
        <p class="page-sub">Your record, your tasks, and what you can do in each company.</p>
      </div>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div v-if="loading" class="empty">Loading your workspace…</div>

      <div v-else class="grid-two">
        <div class="left-column">
          <MyRequestsCard />
          <MyPoliciesCard />
          <div v-if="plan" class="card plan-card">
            <div class="card-head">
              <div>
                <h2>My onboarding</h2>
                <p>Starts {{ plan.start_date }}</p>
              </div>
              <span class="badge" :class="readinessBadgeClass">{{ readinessLabel }}</span>
            </div>
            <div v-for="task in plan.plan_tasks" :key="task.id" class="task-row">
              <div class="row-text">
                <strong>{{ task.title }}</strong>
                <small>{{ task.owner_role }} · due {{ task.due_date ?? '—' }}</small>
              </div>
              <span v-if="task.critical" class="badge">Required before start</span>
              <span class="badge" :class="taskStatusBadgeClass(task.status)">{{ task.status }}</span>
            </div>
          </div>

          <div class="card tasks-card">
            <div class="card-head">
              <div>
                <h2>My tasks</h2>
                <p>Onboarding tasks assigned to you that are still open.</p>
              </div>
            </div>
            <p v-if="taskError" class="error-note" role="alert">{{ taskError }}</p>
            <div v-if="!myTasks.length" class="empty">No tasks assigned to you.</div>
            <div v-for="t in myTasks" :key="t.id" class="task-row">
              <div class="row-text">
                <strong>{{ t.title }}</strong>
                <small v-if="t.due_date">Due {{ t.due_date }}</small>
              </div>
              <div class="row-actions">
                <button
                  class="button secondary small-btn"
                  type="button"
                  :disabled="busyId === t.id"
                  @click="markComplete(t)"
                >
                  Mark complete
                </button>
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

        <div class="right-column">
          <div class="card">
            <div class="card-head">
              <h2>My profile</h2>
            </div>
            <div class="card-body">
              <p class="profile-line"><strong>{{ person?.full_name ?? '—' }}</strong></p>
              <p class="profile-line">{{ person?.work_email ?? '—' }}</p>
              <template v-if="current">
                <p class="profile-line">{{ current.job_title }} · {{ current.company?.name }}</p>
                <p class="profile-line">
                  <span class="badge" :class="employmentBadgeClass(current.status)">
                    {{ current.status.replace('_', ' ') }}
                  </span>
                  started {{ current.start_date }}
                </p>
              </template>
            </div>
            <div class="card-head">
              <h2>Employment history</h2>
            </div>
            <div v-if="!employments.length" class="empty">No employment recorded.</div>
            <div v-for="emp in employments" :key="emp.id" class="emp-row">
              <div class="row-text">
                <strong>{{ emp.job_title }} · {{ emp.company?.name }}</strong>
                <small>{{ emp.start_date }} → {{ emp.end_date ?? 'present' }}</small>
              </div>
              <span class="badge" :class="employmentBadgeClass(emp.status)">
                {{ emp.status.replace('_', ' ') }}
              </span>
            </div>
          </div>

          <CompensationCard v-if="auth.personId" :person-id="auth.personId" :periods="employments" title="My compensation" />
          <DocumentsCard v-if="auth.personId" :person-id="auth.personId" :companies="myCompanies" title="My documents" />

          <div class="card">
            <div class="card-head">
              <h2>My access</h2>
            </div>
            <div class="card-body">
              <p v-if="auth.isAdmin" class="inline-note">
                You are a platform admin: full access across every company.
              </p>
              <div v-if="!grants.length && !auth.isAdmin" class="empty">
                No capabilities granted in any company yet.
              </div>
              <div v-for="g in grants" :key="g.company_id" class="access-block">
                <div class="access-block-head">
                  <strong>{{ g.company?.name }}</strong>
                  <span class="muted-count">{{ g.grant_capabilities.length }} capabilities</span>
                </div>
                <div v-if="!g.grant_capabilities.length" class="empty">No capabilities granted here.</div>
                <ul v-else>
                  <li v-for="label in labelsFor(g)" :key="label">{{ label }}</li>
                </ul>
              </div>
            </div>
          </div>

          <div class="card">
            <div class="card-head">
              <h2>My projects</h2>
            </div>
            <div v-if="!projects.length" class="empty">No project assignments synced.</div>
            <div v-for="p in projects" :key="p.id" class="emp-row">
              <div class="row-text">
                <strong>{{ p.project?.name ?? '—' }}</strong>
                <small v-if="p.project">
                  {{ p.project.source }} · last sync {{ formatSync(p.project.last_synced_at) }}
                </small>
              </div>
              <span class="badge">{{ p.project?.status ?? '—' }}</span>
            </div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.page-head { margin-bottom: 22px; }
.page-sub { margin: 0; font-size: 12px; color: var(--muted); }
.grid-two { display: grid; grid-template-columns: minmax(0, 1.5fr) minmax(260px, 1fr); gap: 22px; }
@media (max-width: 900px) { .grid-two { grid-template-columns: 1fr; } }
.left-column { display: grid; gap: 22px; align-content: start; }
.right-column { display: grid; gap: 22px; align-content: start; }
.task-row {
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
.emp-row { display: flex; align-items: center; gap: 13px; padding: 15px 24px; border-top: 1px solid #edf0eb; }
.profile-line { margin: 0 0 8px; font-size: 12px; }
.inline-note {
  margin: 0 0 14px;
  padding: 10px 14px;
  border-radius: 9px;
  background: var(--green-soft);
  color: var(--green);
  font-size: 11px;
  line-height: 1.5;
}
.access-block { padding: 15px 24px; border-top: 1px solid #edf0eb; }
.access-block-head { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; }
.access-block-head strong { font-size: 12px; font-weight: 550; }
.muted-count { font-size: 10px; color: var(--muted); }
.access-block ul { margin: 10px 0 0; padding-left: 18px; font-size: 11px; color: var(--ink); }
.access-block li { margin-bottom: 4px; }
.access-block .empty { padding: 8px 0 0; text-align: left; }
</style>
