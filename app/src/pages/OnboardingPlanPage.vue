<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import type { Database } from '@/types/database'

type PlanTaskPatch = Database['public']['Tables']['plan_tasks']['Update']

type PlanDetail = {
  id: string
  start_date: string
  status: string
  completed_at: string | null
  person: { id: string; full_name: string } | null
  company: { name: string } | null
  hr_owner: { full_name: string } | null
}

type PlanTaskRow = {
  id: string
  title: string
  description: string | null
  owner_role: string
  phase_key: string
  due_date: string | null
  critical: boolean
  status: string
  blocked_reason: string | null
  skip_reason: string | null
  done_at: string | null
  owner: { full_name: string } | null
}

type Phase = { key: string; label: string; sort_order: number }

const route = useRoute()
const auth = useAuthStore()
const planId = route.params.planId as string

const plan = ref<PlanDetail | null>(null)
const tasks = ref<PlanTaskRow[]>([])
const phases = ref<Phase[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const taskError = ref<string | null>(null)
const busyId = ref<string | null>(null)

const finishBusy = ref(false)
const finishError = ref<string | null>(null)
const finishSuccess = ref<string | null>(null)

const criticalOpen = computed(() =>
  tasks.value.filter((t) => t.critical && t.status !== 'done' && t.status !== 'skipped').length,
)
const readinessBadgeClass = computed(() => (criticalOpen.value ? 'amber' : 'green'))
const readinessLabel = computed(() =>
  criticalOpen.value ? `${criticalOpen.value} readiness gaps` : 'Ready for day one',
)
// Once a plan is completed only "Reopen" stays available on a done task (so a
// mistake stays fixable) — every other task action requires the plan to
// still be in progress.
const canAct = computed(() => plan.value?.status === 'in_progress')
const canFinish = computed(() => plan.value?.status === 'in_progress' && criticalOpen.value === 0)

const phasesGrouped = computed(() =>
  phases.value
    .map((p) => ({ ...p, tasks: tasks.value.filter((t) => t.phase_key === p.key) }))
    .filter((p) => p.tasks.length > 0),
)

function statusBadgeClass(status: string): string {
  if (status === 'done') return 'green'
  if (status === 'blocked') return 'amber'
  if (status === 'open') return 'blue'
  return '' // skipped — neutral/gray, the default badge look
}

function friendlyTaskError(message: string): string {
  if (/row-level security/i.test(message) || /permission/i.test(message)) {
    return 'You do not have permission to change this task.'
  }
  return message
}

async function loadPlan(): Promise<void> {
  error.value = null
  const { data, error: err } = await supabase
    .from('plans')
    .select(
      `id, start_date, status, completed_at,
       person:people!plans_person_id_fkey(id, full_name),
       company:companies(name),
       hr_owner:people!plans_hr_owner_id_fkey(full_name)`,
    )
    .eq('id', planId)
    .maybeSingle()
  if (err || !data) {
    error.value = 'Onboarding plan not found or not visible with your access.'
    console.error('Onboarding plan load failed:', err?.message)
    return
  }
  plan.value = data as PlanDetail
}

async function loadTasks(): Promise<void> {
  taskError.value = null
  const { data, error: err } = await supabase
    .from('plan_tasks')
    .select(
      `id, title, description, owner_role, phase_key, due_date, critical, status,
       blocked_reason, skip_reason, done_at,
       owner:people!plan_tasks_owner_id_fkey(full_name)`,
    )
    .eq('plan_id', planId)
    .order('sort_order', { ascending: true })
  if (err) {
    taskError.value = 'Could not load tasks. Check your access and connection.'
    console.error('Plan tasks load failed:', err.message)
    return
  }
  tasks.value = (data ?? []) as PlanTaskRow[]
}

async function loadPhases(): Promise<void> {
  const { data, error: err } = await supabase
    .from('plan_phases')
    .select('key, label, sort_order')
    .order('sort_order', { ascending: true })
  if (err) {
    console.error('Plan phases load failed:', err.message)
    return
  }
  phases.value = (data ?? []) as Phase[]
}

async function updateTask(task: PlanTaskRow, patch: PlanTaskPatch): Promise<void> {
  taskError.value = null
  busyId.value = task.id
  const { error: err } = await supabase.from('plan_tasks').update(patch).eq('id', task.id)
  busyId.value = null
  if (err) {
    taskError.value = friendlyTaskError(err.message)
    return
  }
  await loadTasks()
}

function markComplete(task: PlanTaskRow): void {
  void updateTask(task, {
    status: 'done',
    done_by: auth.personId,
    done_at: new Date().toISOString(),
  })
}

function reopen(task: PlanTaskRow): void {
  void updateTask(task, { status: 'open', done_by: null, done_at: null })
}

function block(task: PlanTaskRow): void {
  const reason = window.prompt('Why is this blocked?')
  if (!reason || !reason.trim()) return
  void updateTask(task, { status: 'blocked', blocked_reason: reason.trim() })
}

function skip(task: PlanTaskRow): void {
  const reason = window.prompt('Why is this task being skipped?')
  if (!reason || !reason.trim()) return
  void updateTask(task, { status: 'skipped', skip_reason: reason.trim() })
}

async function finishOnboarding(): Promise<void> {
  if (!plan.value) return
  finishError.value = null
  finishBusy.value = true
  const { error: err } = await supabase
    .from('plans')
    .update({ status: 'completed', completed_at: new Date().toISOString() })
    .eq('id', plan.value.id)
  finishBusy.value = false
  if (err) {
    finishError.value = friendlyTaskError(err.message)
    return
  }
  finishSuccess.value = 'Onboarding marked complete.'
  await loadPlan()
}

onMounted(async () => {
  loading.value = true
  await Promise.all([loadPlan(), loadTasks(), loadPhases()])
  loading.value = false
})
</script>

<template>
  <div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-if="loading" class="empty">Loading onboarding plan…</div>

    <template v-else-if="plan">
      <router-link :to="{ name: 'onboarding' }" class="back-link">← Back to Onboarding</router-link>
      <div class="page-head">
        <div>
          <div class="eyebrow">Onboarding</div>
          <h1>{{ plan.person?.full_name ?? '—' }}</h1>
          <p class="plan-meta">
            {{ plan.company?.name ?? '—' }} · starts {{ plan.start_date }} · HR owner
            {{ plan.hr_owner?.full_name ?? '—' }}
          </p>
          <router-link
            v-if="plan.person"
            class="profile-link"
            :to="{ name: 'person', params: { personId: plan.person.id } }"
          >
            Open employee profile
          </router-link>
        </div>
        <span class="badge" :class="readinessBadgeClass">{{ readinessLabel }}</span>
      </div>

      <p v-if="taskError" class="error-note" role="alert">{{ taskError }}</p>

      <div v-for="phase in phasesGrouped" :key="phase.key" class="card phase-card">
        <div class="card-head">
          <h2 class="phase-heading">{{ phase.label }}</h2>
        </div>
        <div>
          <div v-for="task in phase.tasks" :key="task.id" class="task-row">
            <div class="row-text">
              <strong>{{ task.title }}</strong>
              <small>
                {{ task.owner_role }}<template v-if="task.owner?.full_name">
                  · {{ task.owner.full_name }}</template
                >
                · due {{ task.due_date ?? '—' }}
              </small>
              <p v-if="task.blocked_reason" class="reason-note">Blocked: {{ task.blocked_reason }}</p>
              <p v-if="task.skip_reason" class="reason-note">Skipped: {{ task.skip_reason }}</p>
            </div>
            <span v-if="task.critical" class="badge">Required before start</span>
            <span class="badge" :class="statusBadgeClass(task.status)">{{ task.status }}</span>
            <div class="row-actions">
              <button
                v-if="task.status !== 'done' && canAct"
                class="button secondary small-btn"
                type="button"
                :disabled="busyId === task.id"
                @click="markComplete(task)"
              >
                Mark complete
              </button>
              <button
                v-if="task.status === 'done'"
                class="button secondary small-btn"
                type="button"
                :disabled="busyId === task.id"
                @click="reopen(task)"
              >
                Reopen
              </button>
              <button
                v-if="task.status === 'open' && canAct"
                class="button secondary small-btn"
                type="button"
                :disabled="busyId === task.id"
                @click="block(task)"
              >
                Block
              </button>
              <button
                v-if="task.status === 'open' && canAct"
                class="button secondary small-btn"
                type="button"
                :disabled="busyId === task.id"
                @click="skip(task)"
              >
                Skip
              </button>
            </div>
          </div>
        </div>
      </div>

      <div v-if="plan.status === 'completed' || canFinish" class="card footer-card">
        <div class="card-body">
          <p v-if="finishError" class="error-note" role="alert">{{ finishError }}</p>
          <p v-if="finishSuccess" class="success-note">{{ finishSuccess }}</p>
          <span v-if="plan.status === 'completed'" class="badge green">
            Completed {{ (plan.completed_at ?? '').slice(0, 10) }}
          </span>
          <div v-else class="actions">
            <button class="button" type="button" :disabled="finishBusy" @click="finishOnboarding">
              {{ finishBusy ? 'Finishing…' : 'Finish onboarding' }}
            </button>
          </div>
        </div>
      </div>
    </template>
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
.plan-meta { margin: 4px 0 8px; font-size: 11px; color: var(--muted); }
.profile-link { font-size: 11px; }
.phase-card { margin-bottom: 18px; }
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
.reason-note { margin: 6px 0 0; font-size: 11px; color: var(--amber); }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.footer-card { margin-top: 4px; }
.success-note {
  padding: 12px 15px;
  border-radius: 9px;
  background: var(--green-soft);
  color: var(--green);
  font-size: 12px;
  line-height: 1.5;
  margin: 0 0 12px;
}
.actions { display: flex; justify-content: flex-end; }
</style>
