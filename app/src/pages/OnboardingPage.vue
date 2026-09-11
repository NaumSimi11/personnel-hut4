<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'

type PlanTaskLite = { id: string; critical: boolean; status: string }
type PlanRow = {
  id: string
  start_date: string
  status: string
  person: { full_name: string } | null
  company: { name: string } | null
  plan_tasks: PlanTaskLite[]
}

const plans = ref<PlanRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const inProgress = computed(() => plans.value.filter((p) => p.status === 'in_progress'))
const completed = computed(() => plans.value.filter((p) => p.status === 'completed'))

function criticalOpenCount(tasks: PlanTaskLite[]): number {
  return tasks.filter((t) => t.critical && t.status !== 'done' && t.status !== 'skipped').length
}

function doneCount(tasks: PlanTaskLite[]): number {
  return tasks.filter((t) => t.status === 'done').length
}

function readinessBadgeClass(tasks: PlanTaskLite[]): string {
  return criticalOpenCount(tasks) ? 'amber' : 'green'
}

function readinessLabel(tasks: PlanTaskLite[]): string {
  const criticalOpen = criticalOpenCount(tasks)
  return criticalOpen ? `${criticalOpen} readiness gaps` : 'Ready for day one'
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('plans')
    .select(
      `id, start_date, status,
       person:people!plans_person_id_fkey(full_name),
       company:companies(name),
       plan_tasks(id, critical, status)`,
    )
    .eq('kind', 'onboarding')
    .order('start_date', { ascending: true })
  if (err) {
    error.value = 'Could not load onboarding plans. Check your access and connection.'
    console.error('Onboarding plans load failed:', err.message)
  } else {
    plans.value = (data ?? []) as PlanRow[]
  }
  loading.value = false
}

onMounted(load)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">HR operations</div>
        <h1>Make the first day feel prepared.</h1>
      </div>
    </div>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else>
      <div v-if="loading" class="empty">Loading onboarding plans…</div>
      <div v-else-if="!plans.length" class="empty">
        No onboarding plans yet. Confirming a hire creates one automatically.
      </div>
      <template v-else>
        <div class="card section in-progress-section">
          <div class="card-head">
            <div>
              <h2>In progress</h2>
              <p>Plans still being worked before or after the start date.</p>
            </div>
          </div>
          <div v-if="!inProgress.length" class="empty">No onboarding plans in progress.</div>
          <div v-else>
            <div v-for="p in inProgress" :key="p.id" class="plan-row">
              <div class="row-text">
                <strong>{{ p.person?.full_name ?? '—' }}</strong>
                <small
                  >{{ p.company?.name ?? '—' }} · starts {{ p.start_date }} ·
                  {{ doneCount(p.plan_tasks) }}/{{ p.plan_tasks.length }} tasks complete</small
                >
              </div>
              <span class="badge" :class="readinessBadgeClass(p.plan_tasks)">
                {{ readinessLabel(p.plan_tasks) }}
              </span>
              <div class="row-actions">
                <router-link
                  class="button secondary small-btn"
                  :to="{ name: 'onboarding-plan', params: { planId: p.id } }"
                >
                  Open plan
                </router-link>
              </div>
            </div>
          </div>
        </div>

        <details v-if="completed.length" class="card section completed-section">
          <summary class="card-head">
            <div>
              <h2>Completed ({{ completed.length }})</h2>
              <p>Finished onboarding plans — read-only.</p>
            </div>
          </summary>
          <div>
            <div v-for="p in completed" :key="p.id" class="plan-row">
              <div class="row-text">
                <strong>{{ p.person?.full_name ?? '—' }}</strong>
                <small
                  >{{ p.company?.name ?? '—' }} · starts {{ p.start_date }} ·
                  {{ doneCount(p.plan_tasks) }}/{{ p.plan_tasks.length }} tasks complete</small
                >
              </div>
              <span class="badge green">Completed</span>
            </div>
          </div>
        </details>
      </template>
    </div>
  </div>
</template>

<style scoped>
.page-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
}
h1 { margin-bottom: 24px; }
.section { margin-bottom: 22px; }
.completed-section summary { cursor: pointer; list-style: none; }
.completed-section summary::-webkit-details-marker { display: none; }
.plan-row {
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
