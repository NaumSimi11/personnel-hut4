<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import CompanyFilter from '@/components/CompanyFilter.vue'
import ChecklistTasks from '@/components/checklists/ChecklistTasks.vue'
import { OWNER_ROLES, clearConfirmation, filterPlans, planClearable, planMeta, progress, type ChecklistKind, type ChecklistTask, type Phase } from '@/lib/checklists'
import { queueSummary, queueSummaryLine } from '@/lib/queueSummary'
import { todayDb } from '@/lib/compensation'
import { friendlyHardDeleteError } from '@/lib/hardDelete'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'

/**
 * The Onboarding / Offboarding queue (plan 047): every checklist of one
 * kind, filtered by company and by owner ("what is on IT this week"), each
 * expanding inline to the same checkboxes the plan page shows.
 */
const props = defineProps<{ kind: ChecklistKind }>()

type PlanRow = {
  id: string
  company_id: string
  start_date: string
  status: string
  cancelled_reason: string | null
  person: { id: string; full_name: string } | null
  company: { name: string } | null
  employment_period: { end_date: string | null; job_title: string | null } | null
  plan_tasks: ChecklistTask[]
}

const auth = useAuthStore()
const dialogs = useDialogStore()
const plans = ref<PlanRow[]>([])
const phases = ref<Phase[]>([])
const companies = ref<{ id: string; name: string }[]>([])
const companyFilter = ref('')
const ownerFilter = ref('')
const open = ref<Set<string>>(new Set())
const loading = ref(true)
const error = ref<string | null>(null)
// A refusal from Clear belongs next to the Closed list, not in place of the
// whole queue — `error` above empties the page.
const clearError = ref<string | null>(null)
const clearing = ref<string | null>(null)

const isOff = computed(() => props.kind === 'offboarding')
const kindWord = computed(() => (isOff.value ? 'offboarding' : 'onboarding'))
const filtered = computed(() => filterPlans(plans.value, { companyId: companyFilter.value, ownerRole: ownerFilter.value }))
const inProgress = computed(() => filtered.value.filter((p) => p.status === 'in_progress'))
// What the whole queue adds up to, so the top of the page says something
// without the reader totting up every row.
const summaryLine = computed(() => queueSummaryLine(queueSummary(inProgress.value, todayDb()), props.kind))
const closed = computed(() => filtered.value.filter((p) => p.status !== 'in_progress'))

function badgeFor(p: PlanRow): { text: string; cls: string } {
  if (p.status === 'cancelled') return { text: 'Cancelled', cls: '' }
  const b = progress(p.plan_tasks)
  if (p.status === 'completed') return { text: b.criticalOpen ? `completed · ${b.criticalOpen} open` : 'Completed', cls: b.criticalOpen ? 'amber' : 'green' }
  if (isOff.value) return { text: b.criticalOpen ? `${b.criticalOpen} ${b.criticalOpen === 1 ? 'blocker' : 'blockers'}` : 'Ready to close', cls: b.criticalOpen ? 'amber' : 'green' }
  return { text: b.criticalOpen ? `${b.criticalOpen} readiness ${b.criticalOpen === 1 ? 'gap' : 'gaps'}` : 'Ready for day one', cls: b.criticalOpen ? 'amber' : 'green' }
}

function meta(p: PlanRow): string {
  const b = progress(p.plan_tasks)
  return planMeta(
    {
      companyName: p.company?.name ?? null,
      jobTitle: p.employment_period?.job_title ?? null,
      startDate: p.start_date,
      endDate: p.employment_period?.end_date ?? null,
      closed: b.closed,
      total: b.total,
    },
    props.kind,
  )
}

/**
 * Clearing a closed checklist out of the queue (plan 066): the rehire whose
 * old offboarding still sits here describing a departure that was undone.
 * `delete_plan` decides; this is the same rule read ahead of the click.
 */
function clearVerdict(p: PlanRow) {
  return planClearable(p, auth.can(p.company_id, 'tasks.assign'))
}

async function clearPlan(p: PlanRow): Promise<void> {
  const name = p.person?.full_name ?? 'this person'
  const ok = await dialogs.confirmAction({
    title: `Clear ${name}'s ${kindWord.value}?`,
    hint: clearConfirmation(name, props.kind, p.plan_tasks.length),
    confirmLabel: 'Clear checklist',
    danger: true,
  })
  if (!ok) return
  clearError.value = null
  clearing.value = p.id
  const { error: err } = await supabase.rpc('delete_plan', { p_plan_id: p.id })
  clearing.value = null
  if (err) {
    clearError.value = friendlyHardDeleteError(err.message)
    return
  }
  await load()
}

function toggleOpen(id: string): void {
  const next = new Set(open.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  open.value = next
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [plansRes, phasesRes, companiesRes] = await Promise.all([
    supabase
      .from('plans')
      .select(
        `id, company_id, start_date, status, cancelled_reason,
         person:people!plans_person_id_fkey(id, full_name),
         company:companies(name),
         employment_period:employment_periods!plans_employment_period_id_fkey(end_date, job_title),
         plan_tasks(id, title, description, owner_role, phase_key, due_date, critical, status, blocked_reason, skip_reason, done_at, sort_order, owner:people!plan_tasks_owner_id_fkey(full_name))`,
      )
      .eq('kind', props.kind)
      .order('start_date', { ascending: true })
      .order('sort_order', { referencedTable: 'plan_tasks', ascending: true }),
    supabase.from('plan_phases').select('key, label, sort_order').order('sort_order'),
    supabase.from('companies').select('id, name').is('archived_at', null).order('name'),
  ])
  if (plansRes.error) {
    error.value = `Could not load ${props.kind} checklists. Check your access and connection.`
    console.error('Checklists load failed:', plansRes.error.message)
  } else {
    plans.value = (plansRes.data ?? []) as unknown as PlanRow[]
  }
  phases.value = (phasesRes.data ?? []) as Phase[]
  companies.value = companiesRes.data ?? []
  loading.value = false
}

onMounted(load)
</script>

<template>
  <div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else>
      <div class="filters">
        <CompanyFilter v-model="companyFilter" :companies="companies" all-label="All companies" />
        <select v-model="ownerFilter" class="owner" aria-label="Owner" data-testid="owner-filter">
          <option value="">Anyone's lines</option>
          <option v-for="o in OWNER_ROLES" :key="o.key" :value="o.key">On {{ o.label }}</option>
        </select>
      </div>
      <div v-if="loading" class="empty">Loading {{ kind }} checklists…</div>
      <div v-else-if="!plans.length" class="empty">
        {{ isOff ? 'No departures scheduled. Start one from the person\'s employment row.' : 'No onboarding checklists yet. Adding an employee or confirming a hire starts one.' }}
      </div>
      <template v-else>
        <div class="card section in-progress-section">
          <div class="card-head">
            <div>
              <h2>In progress</h2>
              <p>{{ isOff ? 'Scheduled departures with open handover, equipment and access lines.' : 'Checklists still being worked before or after the start date.' }}</p>
            </div>
            <p v-if="summaryLine" class="queue-summary">{{ summaryLine }}</p>
          </div>
          <div v-if="!inProgress.length" class="empty">Nothing in progress{{ companyFilter || ownerFilter ? ' for this filter' : '' }}.</div>
          <div v-for="p in inProgress" :key="p.id" class="plan" :data-testid="`plan-${p.id}`">
            <div class="plan-row">
              <button type="button" class="expander" :aria-expanded="open.has(p.id)" :aria-label="`Show ${p.person?.full_name ?? ''}'s checklist`" @click="toggleOpen(p.id)">{{ open.has(p.id) ? '▾' : '▸' }}</button>
              <div class="row-text">
                <router-link v-if="p.person" class="person-link" :to="{ name: 'person', params: { personId: p.person.id } }"><strong>{{ p.person.full_name }}</strong></router-link>
                <strong v-else>—</strong>
                <small>{{ meta(p) }}</small>
              </div>
              <span class="badge" :class="badgeFor(p).cls">{{ badgeFor(p).text }}</span>
              <div class="row-actions">
                <router-link class="button secondary small-btn" :to="{ name: isOff ? 'offboarding-plan' : 'onboarding-plan', params: { planId: p.id } }">Open</router-link>
              </div>
            </div>
            <div v-if="open.has(p.id)" class="inline">
              <ChecklistTasks :plan-id="p.id" :company-id="p.company_id" :kind="kind" :tasks="p.plan_tasks" :phases="phases" :active="true" compact @changed="load" />
            </div>
          </div>
        </div>

        <details v-if="closed.length" class="card section completed-section">
          <summary class="card-head">
            <div>
              <h2>Closed ({{ closed.length }})</h2>
              <p>{{ isOff ? 'People marked as former, and cancelled departures.' : 'Finished and cancelled checklists.' }}</p>
            </div>
          </summary>
          <div>
            <p v-if="clearError" class="error-note" role="alert">{{ clearError }}</p>
            <div v-for="p in closed" :key="p.id" class="plan-row">
              <div class="row-text">
                <router-link v-if="p.person" class="person-link" :to="{ name: 'person', params: { personId: p.person.id } }"><strong>{{ p.person.full_name }}</strong></router-link>
                <strong v-else>—</strong>
                <small>{{ meta(p) }}<template v-if="p.cancelled_reason"> · {{ p.cancelled_reason }}</template></small>
              </div>
              <span class="badge" :class="badgeFor(p).cls">{{ badgeFor(p).text }}</span>
              <div class="row-actions">
                <router-link class="button secondary small-btn" :to="{ name: isOff ? 'offboarding-plan' : 'onboarding-plan', params: { planId: p.id } }">Open</router-link>
                <button
                  v-if="clearVerdict(p).canClear"
                  type="button"
                  class="button danger small-btn"
                  :disabled="clearing === p.id"
                  :data-testid="`clear-plan-${p.id}`"
                  @click="clearPlan(p)"
                >
                  {{ clearing === p.id ? 'Clearing…' : 'Clear' }}
                </button>
              </div>
            </div>
          </div>
        </details>
      </template>
    </div>
  </div>
</template>

<style scoped>
.queue-summary { margin: 0; font-size: 12px; font-weight: 600; color: var(--ink); white-space: nowrap; }
.filters { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; margin-bottom: 16px; }
.owner { border: 1px solid var(--line); background: #fafbf9; padding: 9px 12px; font-size: 12px; }
.section { margin-bottom: 22px; }
.completed-section summary { cursor: pointer; list-style: none; }
.completed-section summary::-webkit-details-marker { display: none; }
.plan-row { display: flex; align-items: center; gap: 13px; padding: 15px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.expander { border: 0; background: none; font-size: 12px; color: var(--muted); cursor: pointer; width: 20px; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.person-link { text-decoration: none; color: inherit; }
.person-link:hover strong { color: var(--green); text-decoration: underline; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.inline { padding: 0 24px 8px 57px; background: #fafbf8; border-top: 1px solid #edf0eb; }
</style>
