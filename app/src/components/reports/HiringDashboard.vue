<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'

/**
 * The hiring dashboard (0111; spec 9.14): open requests by status and
 * department, time to fill and the offer acceptance rate for the company and
 * range picked above. Time to hire is in the KPIs above it.
 */
const props = defineProps<{ companyId: string; from: string; to: string }>()

type Dashboard = {
  open_requests: { status: string; department: string; count: number }[]
  time_to_fill: { jobs: number; median_days: number | null; avg_days: number | null }
  offers: { accepted: number; declined: number; rate: number | null }
}
const STATUS_LABEL: Record<string, string> = {
  draft: 'Draft', submitted: 'Pending approval', changes_requested: 'Changes requested', approved: 'Approved', on_hold: 'On hold',
}

const data = ref<Dashboard | null>(null)
const error = ref<string | null>(null)

const departments = computed(() => [...new Set((data.value?.open_requests ?? []).map((r) => r.department))].sort())
const statuses = computed(() => Object.keys(STATUS_LABEL).filter((s) => (data.value?.open_requests ?? []).some((r) => r.status === s)))
function cell(status: string, department: string): number {
  return data.value?.open_requests.find((r) => r.status === status && r.department === department)?.count ?? 0
}

async function load(): Promise<void> {
  if (!props.companyId || !props.from || !props.to) return
  error.value = null
  const { data: res, error: err } = await supabase.rpc('hiring_dashboard', { p_company_id: props.companyId, p_from: props.from, p_to: props.to })
  if (err) {
    console.error('hiring_dashboard failed:', err.message)
    error.value = /jobs\.view/.test(err.message) ? 'You need jobs.view in this company to see the dashboard.' : 'Could not load the hiring dashboard.'
    data.value = null
    return
  }
  data.value = res as unknown as Dashboard
}

watch(() => [props.companyId, props.from, props.to], load, { immediate: true })
</script>

<template>
  <section class="card dashboard" aria-label="Hiring dashboard">
    <div class="card-head">
      <div>
        <h2>Hiring dashboard</h2>
        <p>Open requests now; time to fill and offer answers in the range.</p>
      </div>
    </div>
    <div class="card-body">
    <p v-if="error" class="error" role="alert">{{ error }}</p>
    <template v-else-if="data">
      <div class="tiles">
        <div class="tile">
          <span class="label">Time to fill</span>
          <strong>{{ data.time_to_fill.median_days ?? '—' }}<small v-if="data.time_to_fill.median_days !== null"> days</small></strong>
          <small>median of {{ data.time_to_fill.jobs }} filled job{{ data.time_to_fill.jobs === 1 ? '' : 's' }}</small>
        </div>
        <div class="tile">
          <span class="label">Offer acceptance</span>
          <strong>{{ data.offers.rate !== null ? `${data.offers.rate}%` : '—' }}</strong>
          <small>{{ data.offers.accepted }} accepted · {{ data.offers.declined }} declined</small>
        </div>
      </div>
      <div v-if="statuses.length" class="table-wrap">
        <table>
          <thead>
            <tr><th>Department</th><th v-for="s in statuses" :key="s">{{ STATUS_LABEL[s] }}</th></tr>
          </thead>
          <tbody>
            <tr v-for="d in departments" :key="d">
              <th scope="row">{{ d }}</th>
              <td v-for="s in statuses" :key="s">{{ cell(s, d) || '' }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p v-else class="empty-line">No open hiring requests.</p>
    </template>
    </div>
  </section>
</template>

<style scoped>
.dashboard { display: grid; gap: 12px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px; }
.tile { border: 1px solid var(--line); border-radius: 10px; padding: 12px; display: grid; gap: 2px; }
.tile .label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
.tile strong { font-size: 1.5rem; font-variant-numeric: tabular-nums; }
.tile small { color: var(--muted); }
.table-wrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--line); }
td { font-variant-numeric: tabular-nums; }
.empty-line { margin: 0; color: var(--muted); font-size: 12px; }
.error { margin: 0; color: var(--red, #b42318); }
</style>
