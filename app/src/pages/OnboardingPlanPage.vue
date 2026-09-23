<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { friendlyDepartureError } from '@/lib/departure'
import { progress, type ChecklistKind, type ChecklistTask, type Phase } from '@/lib/checklists'
import { nextAction, nextActionSentence } from '@/lib/nextAction'
import { planSections, type PlanSectionId } from '@/lib/planSections'
import { planStep } from '@/lib/journey'
import JobStepper from '@/components/JobStepper.vue'
import { todayDb } from '@/lib/compensation'
import ChecklistTasks from '@/components/checklists/ChecklistTasks.vue'
import HandoverCard from '@/components/handover/HandoverCard.vue'
import StarterKitCard from '@/components/equipment/StarterKitCard.vue'
import AccessCard from '@/components/access/AccessCard.vue'
import WelcomeNoteCard from '@/components/welcome/WelcomeNoteCard.vue'
import { deliverNotifications } from '@/lib/notificationsApi'

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
const auth = useAuthStore()
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
// The single line worth doing next, so the reader does not have to derive it
// from a list where every line looks equally urgent.
const next = computed(() => (plan.value ? nextAction(tasks.value, plan.value.kind, todayDb()) : null))
const nextSentence = computed(() => (next.value ? nextActionSentence(next.value) : null))

// The readiness count is the most useful number on the page; clicking it should
// take you to what it is counting rather than leaving you to find it.
const CLOSED_STATES = new Set(['done', 'skipped'])
const firstGapId = computed(
  () => tasks.value.find((t) => t.critical && !CLOSED_STATES.has(t.status))?.id ?? null,
)
// The same strip the job page shows, carried past "Hired" so the hiring half
// and the onboarding half read as one journey rather than two tools.
const journeyStep = computed(() =>
  plan.value ? planStep({ status: plan.value.status, startDate: plan.value.start_date }, todayDb()) : null,
)

// The starter kit card renders nothing when the company has configured no kit,
// so the nav must not offer a link to it. It reports back on load.
const kitPresent = ref(true)
const navSections = computed(() => sections.value.filter((sec) => sec.id !== 'kit' || kitPresent.value))

const sections = computed(() =>
  plan.value
    ? planSections({
        kind: plan.value.kind,
        hasPerson: Boolean(plan.value.person),
        canViewTasks: auth.can(plan.value.company_id, 'tasks.view'),
        canViewIt: auth.can(plan.value.company_id, 'it.view'),
      })
    : [],
)
function goToSection(id: PlanSectionId): void {
  document.getElementById(`plan-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function goToFirstGap(): void {
  const id = firstGapId.value
  if (!id) return
  const row = document.querySelector(`[data-testid="task-${id}"]`)
  row?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  row?.querySelector<HTMLInputElement>('input[type="checkbox"]')?.focus()
}
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
  void deliverNotifications()
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
        <button
          v-else-if="firstGapId"
          type="button"
          class="badge readiness-badge amber is-link"
          :title="`Go to the first ${isOffboarding ? 'blocker' : 'gap'}`"
          @click="goToFirstGap"
        >{{ readinessLabel }}</button>
        <span v-else class="badge readiness-badge green">{{ readinessLabel }}</span>
      </div>

      <JobStepper v-if="!isOffboarding && journeyStep" :current="journeyStep" label="Employee journey" />

      <div v-if="active && next && nextSentence" class="card next-card">
        <div>
          <span class="eyebrow">Next</span>
          <p class="next-line" :class="{ late: next.overdue || next.task.status === 'blocked' }">{{ nextSentence }}</p>
        </div>
        <span class="badge" :class="next.task.critical ? 'amber' : 'green'">
          {{ next.task.critical ? 'Required' : 'Optional' }}
        </span>
      </div>

      <nav v-if="navSections.length > 1" class="section-nav" aria-label="Sections of this plan">
        <button v-for="sec in navSections" :key="sec.id" type="button" class="section-link" @click="goToSection(sec.id)">
          {{ sec.label }}
        </button>
      </nav>

      <div id="plan-checklist" class="card">
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

      <WelcomeNoteCard
        :id="`plan-welcome`"
        v-if="plan.kind === 'onboarding' && auth.can(plan.company_id, 'tasks.view')"
        class="handover"
        :plan-id="plan.id"
        :company-id="plan.company_id"
        @changed="loadTasks"
      />

      <StarterKitCard
        :id="`plan-kit`"
        @present="kitPresent = $event"
        v-if="plan.kind === 'onboarding' && plan.person && auth.can(plan.company_id, 'it.view')"
        class="handover"
        :plan-id="plan.id"
        :person-id="plan.person.id"
        :company-id="plan.company_id"
        @changed="loadTasks"
      />

      <AccessCard
        :id="`plan-access`"
        v-if="plan.person"
        class="handover"
        :person-id="plan.person.id"
        :company-id="plan.company_id"
        :kind="plan.kind"
        @changed="loadTasks"
      />

      <HandoverCard
        :id="`plan-handover`"
        v-if="plan.person && auth.can(plan.company_id, 'tasks.view')"
        class="handover"
        :plan-id="plan.id"
        :person-id="plan.person.id"
        :company-id="plan.company_id"
        :kind="plan.kind"
        @changed="loadTasks"
      />

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
/* The sticky nav would otherwise cover the heading it just jumped to. */
#plan-checklist, #plan-welcome, #plan-kit, #plan-access, #plan-handover { scroll-margin-top: 64px; }
.section-nav { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 14px; position: sticky; top: 0; z-index: 2; padding: 8px 0; background: var(--paper, #f6f8f3); }
.section-link { font-size: 12px; font-weight: 600; color: var(--ink); background: #fff; border: 1px solid #e3e7de; border-radius: 999px; padding: 6px 14px; cursor: pointer; }
.section-link:hover { background: #f2f5ee; }
.badge.is-link { cursor: pointer; border: 0; font: inherit; font-size: 11px; }
.badge.is-link:hover { filter: brightness(0.96); }
.next-card { display: flex; align-items: center; justify-content: space-between; gap: 18px; padding: 16px 24px; margin-bottom: 14px; flex-wrap: wrap; }
.next-line { margin: 4px 0 0; font-size: 14px; font-weight: 600; }
.next-line.late { color: #a8332b; }
.back-link { display: inline-block; font-size: 11px; color: var(--muted); text-decoration: none; margin-bottom: 14px; }
.back-link:hover { color: var(--green); text-decoration: underline; }
.page-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 22px; }
.plan-meta { margin: 4px 0 8px; font-size: 11px; color: var(--muted); }
.profile-link { font-size: 11px; }
.footer-card { margin-top: 18px; }
.handover { margin-top: 18px; }
.success-note { padding: 12px 15px; border-radius: 9px; background: var(--green-soft); color: var(--green); font-size: 12px; line-height: 1.5; margin: 0 0 12px; }
.actions { display: flex; justify-content: flex-end; }
</style>
