<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'

/**
 * The offboarding queue (plan 016): every scheduled departure with its plan.
 * A plan's start_date is the last working day (schedule_departure, 0010);
 * the employment end date comes from the period. Blockers are the open
 * critical tasks — equipment and access removal, typically.
 */

type PlanTaskLite = { id: string; critical: boolean; status: string }
type PlanRow = {
  id: string
  start_date: string
  status: string
  person: { id: string; full_name: string } | null
  company: { name: string } | null
  employment_period: { end_date: string | null; status: string } | null
  plan_tasks: PlanTaskLite[]
}

const plans = ref<PlanRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const inProgress = computed(() => plans.value.filter((p) => p.status === 'in_progress'))
const completed = computed(() => plans.value.filter((p) => p.status === 'completed'))

function blockerCount(tasks: PlanTaskLite[]): number {
  return tasks.filter((t) => t.critical && t.status !== 'done' && t.status !== 'skipped').length
}

function doneCount(tasks: PlanTaskLite[]): number {
  return tasks.filter((t) => t.status === 'done').length
}

function blockerBadgeClass(tasks: PlanTaskLite[]): string {
  return blockerCount(tasks) ? 'amber' : 'green'
}

function blockerLabel(tasks: PlanTaskLite[]): string {
  const n = blockerCount(tasks)
  return n ? `${n} ${n === 1 ? 'blocker' : 'blockers'}` : 'Ready to close'
}

function rowMeta(p: PlanRow): string {
  const parts = [p.company?.name ?? '—', `last day ${p.start_date}`]
  if (p.employment_period?.end_date && p.employment_period.end_date !== p.start_date) {
    parts.push(`employment ends ${p.employment_period.end_date}`)
  }
  parts.push(`${doneCount(p.plan_tasks)}/${p.plan_tasks.length} tasks complete`)
  return parts.join(' · ')
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('plans')
    .select(
      `id, start_date, status,
       person:people!plans_person_id_fkey(id, full_name),
       company:companies(name),
       employment_period:employment_periods!plans_employment_period_id_fkey(end_date, status),
       plan_tasks(id, critical, status)`,
    )
    .eq('kind', 'offboarding')
    .order('start_date', { ascending: true })
  if (err) {
    error.value = 'Could not load offboarding plans. Check your access and connection.'
    console.error('Offboarding plans load failed:', err.message)
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
        <h1>Offboarding, handled properly.</h1>
        <p class="page-sub">
          Departures are scheduled from a person's employment record. People stay active until they
          are explicitly marked as former.
        </p>
      </div>
    </div>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else>
      <div v-if="loading" class="empty">Loading offboarding plans…</div>
      <div v-else-if="!plans.length" class="empty">
        No departures scheduled. Start one from the person's employment row.
      </div>
      <template v-else>
        <div class="card section">
          <div class="card-head">
            <div>
              <h2>In progress</h2>
              <p>Scheduled departures with open handover, equipment and access tasks.</p>
            </div>
          </div>
          <div v-if="!inProgress.length" class="empty">No departures in progress.</div>
          <div v-else>
            <div v-for="p in inProgress" :key="p.id" class="plan-row">
              <div class="row-text">
                <router-link
                  v-if="p.person"
                  class="person-link"
                  :to="{ name: 'person', params: { personId: p.person.id } }"
                >
                  <strong>{{ p.person.full_name }}</strong>
                </router-link>
                <strong v-else>—</strong>
                <small>{{ rowMeta(p) }}</small>
              </div>
              <span class="badge" :class="blockerBadgeClass(p.plan_tasks)">
                {{ blockerLabel(p.plan_tasks) }}
              </span>
              <div class="row-actions">
                <router-link
                  class="button secondary small-btn"
                  :to="{ name: 'offboarding-plan', params: { planId: p.id } }"
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
              <p>People marked as former. Any tasks left open can still be finished from the plan.</p>
            </div>
          </summary>
          <div>
            <div v-for="p in completed" :key="p.id" class="plan-row">
              <div class="row-text">
                <router-link
                  v-if="p.person"
                  class="person-link"
                  :to="{ name: 'person', params: { personId: p.person.id } }"
                >
                  <strong>{{ p.person.full_name }}</strong>
                </router-link>
                <strong v-else>—</strong>
                <small>{{ rowMeta(p) }}</small>
              </div>
              <span class="badge" :class="blockerCount(p.plan_tasks) ? 'amber' : 'green'">
                completed{{ blockerCount(p.plan_tasks) ? ` · ${blockerCount(p.plan_tasks)} open` : '' }}
              </span>
              <div class="row-actions">
                <router-link
                  class="button secondary small-btn"
                  :to="{ name: 'offboarding-plan', params: { planId: p.id } }"
                >
                  Open plan
                </router-link>
              </div>
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
  margin-bottom: 24px;
}
.page-sub { margin: 0; font-size: 12px; color: var(--muted); max-width: 560px; }
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
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.person-link { text-decoration: none; color: inherit; }
.person-link:hover strong { color: var(--green); text-decoration: underline; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
