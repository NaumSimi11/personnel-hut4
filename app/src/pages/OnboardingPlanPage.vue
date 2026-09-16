<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useDialogStore } from '@/stores/dialogs'
import { friendlyDepartureError } from '@/lib/departure'
import { progress, type ChecklistKind, type ChecklistTask, type Phase } from '@/lib/checklists'
import ChecklistTasks from '@/components/checklists/ChecklistTasks.vue'

/**
 * One person's checklist, either kind (plan 047): the lines as checkboxes,
 * a progress bar, the one-off task. Onboarding and offboarding share
 * everything but the wording and what "finish" means — onboarding closes
 * the plan, offboarding is the explicit act of becoming Former
 * (complete_departure, migration 0010) and may leave lines open.
 */
type PlanDetail = {
  id: string
  kind: ChecklistKind
  company_id: string
  start_date: string
  status: string
  completed_at: string | null
  cancelled_reason: string | null
  person: { id: string; full_name: string } | null
  company: { name: string } | null
  hr_owner: { full_name: string } | null
  employment_period: { id: string; end_date: string | null } | null
}

const route = useRoute()
const dialogs = useDialogStore()
const planId = route.params.planId as string

const plan = ref<PlanDetail | null>(null)
const tasks = ref<ChecklistTask[]>([])
const phases = ref<Phase[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const finishBusy = ref(false)
const finishError = ref<string | null>(null)
const finishSuccess = ref<string | null>(null)

const bar = computed(() => progress(tasks.value))
const isOffboarding = computed(() => (plan.value ? plan.value.kind === 'offboarding' : route.name === 'offboarding-plan'))
const readinessLabel = computed(() => {
  const n = bar.value.criticalOpen
  if (isOffboarding.value) return n ? `${n} ${n === 1 ? 'blocker' : 'blockers'}` : 'Ready to close'
  return n ? `${n} readiness ${n === 1 ? 'gap' : 'gaps'}` : 'Ready for day one'
})
const labels = computed(() =>
  isOffboarding.value
    ? { eyebrow: 'Offboarding', queue: 'offboarding' as const, back: '← Back to Offboarding', loading: 'Loading offboarding checklist…', notFound: 'Offboarding checklist not found or not visible with your access.', date: 'last day', finish: 'Finish offboarding', finishing: 'Finishing…' }
    : { eyebrow: 'Onboarding', queue: 'onboarding' as const, back: '← Back to Onboarding', loading: 'Loading onboarding checklist…', notFound: 'Onboarding checklist not found or not visible with your access.', date: 'starts', finish: 'Finish onboarding', finishing: 'Finishing…' },
)
// Offboarding lines stay workable after the person is former; onboarding closes with the plan.
const active = computed(() => plan.value?.status === 'in_progress' || (isOffboarding.value && plan.value?.status === 'completed'))
const canFinish = computed(() => plan.value?.status === 'in_progress' && (isOffboarding.value || bar.value.criticalOpen === 0))

async function loadPlan(): Promise<void> {
  error.value = null
  const { data, error: err } = await supabase
    .from('plans')
    .select(
      `id, kind, company_id, start_date, status, completed_at, cancelled_reason,
       person:people!plans_person_id_fkey(id, full_name),
       company:companies(name),
       hr_owner:people!plans_hr_owner_id_fkey(full_name),
       employment_period:employment_periods!plans_employment_period_id_fkey(id, end_date)`,
    )
    .eq('id', planId)
    .maybeSingle()
  if (err || !data) {
    error.value = labels.value.notFound
    console.error('Plan load failed:', err?.message)
    return
  }
  plan.value = data as PlanDetail
}

async function loadTasks(): Promise<void> {
  const { data, error: err } = await supabase
    .from('plan_tasks')
    .select(`id, title, description, owner_role, phase_key, due_date, critical, status, blocked_reason, skip_reason, done_at, owner:people!plan_tasks_owner_id_fkey(full_name)`)
    .eq('plan_id', planId)
    .order('sort_order', { ascending: true })
  if (err) {
    error.value = 'Could not load the checklist. Check your access and connection.'
    console.error('Plan tasks load failed:', err.message)
    return
  }
  tasks.value = (data ?? []) as ChecklistTask[]
}

async function loadPhases(): Promise<void> {
  const { data, error: err } = await supabase.from('plan_phases').select('key, label, sort_order').order('sort_order', { ascending: true })
  if (err) {
    console.error('Plan phases load failed:', err.message)
    return
  }
  phases.value = (data ?? []) as Phase[]
}

async function finishPlan(): Promise<void> {
  if (!plan.value) return
  if (isOffboarding.value) return finishOffboarding()
  finishError.value = null
  finishBusy.value = true
  const { error: err } = await supabase.from('plans').update({ status: 'completed', completed_at: new Date().toISOString() }).eq('id', plan.value.id)
  finishBusy.value = false
  if (err) {
    finishError.value = /row-level security/i.test(err.message) ? 'You do not have permission to close this checklist.' : err.message
    return
  }
  finishSuccess.value = 'Onboarding marked complete.'
  await loadPlan()
}

/** The explicit act of becoming Former; the RPC closes the plan too. */
async function finishOffboarding(): Promise<void> {
  const periodId = plan.value?.employment_period?.id
  if (!plan.value || !periodId) {
    finishError.value = 'This checklist is not linked to an employment period.'
    return
  }
  const open = bar.value.criticalOpen
  const ok = await dialogs.confirmAction({
    title: `Mark ${plan.value.person?.full_name ?? 'this person'} as former?`,
    hint: open ? `${open} critical ${open === 1 ? 'line is' : 'lines are'} still open; they stay on the checklist.` : 'The employment ends and the checklist is completed with it.',
    confirmLabel: 'Mark as former',
    danger: true,
  })
  if (!ok) return
  finishError.value = null
  finishBusy.value = true
  const { data, error: err } = await supabase.rpc('complete_departure', { p_employment_period_id: periodId })
  finishBusy.value = false
  if (err) {
    finishError.value = friendlyDepartureError(err.message)
    return
  }
  const left = (data as { open_tasks: number })?.open_tasks ?? 0
  finishSuccess.value = left ? `Now former. ${left} ${left === 1 ? 'task' : 'tasks'} still open — finish them from this checklist.` : 'Now former. Every offboarding task is closed.'
  await Promise.all([loadPlan(), loadTasks()])
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
    <div v-if="loading" class="empty">{{ labels.loading }}</div>

    <template v-else-if="plan">
      <router-link :to="{ name: labels.queue }" class="back-link">{{ labels.back }}</router-link>
      <div class="page-head">
        <div>
          <div class="eyebrow">{{ labels.eyebrow }}</div>
          <h1>{{ plan.person?.full_name ?? '—' }}</h1>
          <p class="plan-meta">
            {{ plan.company?.name ?? '—' }} · {{ labels.date }} {{ plan.start_date }}
            <template v-if="isOffboarding && plan.employment_period?.end_date && plan.employment_period.end_date !== plan.start_date">
              · employment ends {{ plan.employment_period.end_date }}
            </template>
            · HR owner {{ plan.hr_owner?.full_name ?? '—' }}
          </p>
          <router-link v-if="plan.person" class="profile-link" :to="{ name: 'person', params: { personId: plan.person.id } }">
            Open employee profile
          </router-link>
        </div>
        <span v-if="plan.status === 'cancelled'" class="badge readiness-badge">Cancelled<template v-if="plan.cancelled_reason"> · {{ plan.cancelled_reason }}</template></span>
        <span v-else class="badge readiness-badge" :class="bar.criticalOpen ? 'amber' : 'green'">{{ readinessLabel }}</span>
      </div>

      <div class="card">
        <ChecklistTasks
          :plan-id="plan.id"
          :company-id="plan.company_id"
          :kind="plan.kind"
          :tasks="tasks"
          :phases="phases"
          :active="active"
          @changed="loadTasks"
        />
      </div>

      <div v-if="plan.status === 'completed' || canFinish" class="card footer-card">
        <div class="card-body">
          <p v-if="finishError" class="error-note" role="alert">{{ finishError }}</p>
          <p v-if="finishSuccess" class="success-note">{{ finishSuccess }}</p>
          <span v-if="plan.status === 'completed'" class="badge green">Completed {{ (plan.completed_at ?? '').slice(0, 10) }}</span>
          <div v-else class="actions">
            <button class="button" type="button" :disabled="finishBusy" @click="finishPlan">
              {{ finishBusy ? labels.finishing : labels.finish }}
            </button>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.back-link { display: inline-block; font-size: 11px; color: var(--muted); text-decoration: none; margin-bottom: 14px; }
.back-link:hover { color: var(--green); text-decoration: underline; }
.page-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 22px; }
.plan-meta { margin: 4px 0 8px; font-size: 11px; color: var(--muted); }
.profile-link { font-size: 11px; }
.footer-card { margin-top: 18px; }
.success-note { padding: 12px 15px; border-radius: 9px; background: var(--green-soft); color: var(--green); font-size: 12px; line-height: 1.5; margin: 0 0 12px; }
.actions { display: flex; justify-content: flex-end; }
</style>
