<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import CompanyFilter from '@/components/CompanyFilter.vue'
import RecruitmentTiming from '@/components/reports/RecruitmentTiming.vue'
import { useAuthStore } from '@/stores/auth'
import {
  STAGE_ORDER,
  conversion,
  defaultRange,
  funnelCsv,
  parseReport,
  type RecruitmentReport,
} from '@/lib/reporting'

/**
 * Recruitment reports (plan 021). Pick a company and a date range; the
 * database counts (recruitment_report, migration 0015) and this page lays
 * the numbers out: KPIs, the per-job funnel, where candidates came from, and
 * what needs attention. Counts only — no candidate names leave the server.
 * Below them, the hiring speed (plan 067) has its own RPC and names hires
 * only to a viewer who holds candidates.view.
 */

type CompanyOption = { id: string; name: string }

const auth = useAuthStore()
const companies = ref<CompanyOption[]>([])
const companyId = ref('')
const range = ref(defaultRange())
const report = ref<RecruitmentReport | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)

const STAGE_LABELS: Record<(typeof STAGE_ORDER)[number], string> = {
  new: 'New',
  screening: 'Screening',
  interview: 'Interview',
  offer: 'Offer',
  hired: 'Hired',
  rejected: 'Rejected',
  withdrawn: 'Withdrawn',
}

const kpiTiles = computed(() => {
  const k = report.value?.kpis
  if (!k) return []
  return [
    { label: 'Open roles', value: String(k.open_roles) },
    { label: 'Active candidates', value: String(k.active_candidates) },
    { label: 'Received', value: String(k.received) },
    { label: 'Hires', value: String(k.hires) },
    { label: 'Median days to hire', value: k.median_days_to_hire === null ? '—' : String(k.median_days_to_hire) },
  ]
})

const attentionTiles = computed(() => {
  const a = report.value?.attention
  if (!a) return []
  return [
    { label: 'Overdue next actions', value: a.overdue_next_actions, hint: 'Next action date has passed.' },
    { label: 'Unassigned', value: a.unassigned, hint: 'Open applications with no owner.' },
    { label: 'Stale', value: a.stale, hint: 'No stage change in 14 days.' },
    { label: 'Not responding', value: a.not_responding, hint: 'Sourced or contacted, no activity in 30 days.' },
  ]
})

async function loadCompanies(): Promise<void> {
  // The report itself checks jobs.view; the picker shows what the person can see.
  const { data } = await supabase
    .from('companies')
    .select('id, name')
    .is('archived_at', null)
    .order('name')
  companies.value = (data ?? []).filter((c) => auth.can(c.id, 'jobs.view'))
  if (!companyId.value && companies.value[0]) companyId.value = companies.value[0].id
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/
const rangeProblem = computed(() => {
  if (!ISO_DATE.test(range.value.from) || !ISO_DATE.test(range.value.to)) return 'Choose both dates.'
  if (range.value.to < range.value.from) return 'The end date is before the start date.'
  return null
})

// Responses can arrive out of order when the company or range changes
// quickly; only the latest request may write the report.
let requestSeq = 0

async function load(): Promise<void> {
  if (!companyId.value || rangeProblem.value) return
  const seq = ++requestSeq
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase.rpc('recruitment_report', {
    p_company_id: companyId.value,
    p_from: range.value.from,
    p_to: range.value.to,
  })
  if (seq !== requestSeq) return
  loading.value = false
  if (err) {
    report.value = null
    error.value = /jobs\.view/.test(err.message) ? 'You need jobs.view in this company to see its report.' : err.message
    return
  }
  try {
    report.value = parseReport(data)
  } catch (e) {
    report.value = null
    error.value = 'The report came back in an unexpected shape.'
    console.error('Report parse failed:', e)
  }
}

function exportCsv(): void {
  if (!report.value) return
  const company = companies.value.find((c) => c.id === companyId.value)?.name ?? 'company'
  const blob = new Blob([funnelCsv(report.value)], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `recruitment-funnel-${company.toLowerCase().replace(/\s+/g, '-')}-${range.value.from}-to-${range.value.to}.csv`
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}

// loadCompanies picks the first company, and that change is what triggers
// the first load — one fetch on mount, not two.
onMounted(loadCompanies)

watch([companyId, () => range.value.from, () => range.value.to], load)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">Recruitment</div>
        <h1>Reports</h1>
        <p class="page-sub">Counted in the database from real applications. Unknown sources stay unknown.</p>
      </div>
    </div>

    <div class="card controls">
      <CompanyFilter id="report-company" v-model="companyId" :companies="companies" label="Company" />
      <div class="field">
        <label for="report-from">From</label>
        <input id="report-from" v-model="range.from" type="date" />
      </div>
      <div class="field">
        <label for="report-to">To</label>
        <input id="report-to" v-model="range.to" type="date" />
      </div>
      <button class="button secondary" type="button" :disabled="!report" @click="exportCsv">Export funnel (CSV)</button>
    </div>

    <p v-if="rangeProblem" class="inline-warning">{{ rangeProblem }}</p>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else-if="!companies.length" class="empty">You do not have jobs.view in any company.</div>
    <div v-else-if="loading && !report" class="empty">Counting…</div>

    <template v-else-if="report">
      <div class="report-ready" :class="{ dim: loading }">
        <div class="kpis">
          <div v-for="k in kpiTiles" :key="k.label" class="card kpi">
            <span class="kpi-label">{{ k.label }}</span>
            <span class="kpi-value">{{ k.value }}</span>
          </div>
        </div>

        <div class="card section">
          <div class="card-head">
            <div>
              <h2>Funnel by job</h2>
              <p>Current stage of every application; "received" counts arrivals in the range.</p>
            </div>
          </div>
          <div v-if="!report.funnel.length" class="empty">No jobs with activity in this range.</div>
          <div v-else class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Job</th>
                  <th>Status</th>
                  <th>Received</th>
                  <th v-for="s in STAGE_ORDER" :key="s">{{ STAGE_LABELS[s] }}</th>
                  <th>Hire rate</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="f in report.funnel" :key="f.job_id" class="funnel-row">
                  <td>
                    <router-link class="job-link" :to="{ name: 'job', params: { jobId: f.job_id } }">{{ f.title }}</router-link>
                  </td>
                  <td><span class="badge" :class="f.status === 'open' ? 'green' : ''">{{ f.status.replace('_', ' ') }}</span></td>
                  <td data-col="received">{{ f.received }}</td>
                  <td v-for="s in STAGE_ORDER" :key="s" :data-col="s">{{ f.stages[s] }}</td>
                  <td>{{ conversion(f.hired, f.received) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="two-up">
          <div class="card section">
            <div class="card-head">
              <div>
                <h2>Sources</h2>
                <p>Where applications in the range came from, and how far they got.</p>
              </div>
            </div>
            <div v-if="!report.sources.length" class="empty">No applications received in this range.</div>
            <div v-else class="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Source</th>
                    <th>Received</th>
                    <th>Interviewed</th>
                    <th>Hired</th>
                    <th>Interview rate</th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-for="s in report.sources" :key="s.source" class="source-row">
                    <td>{{ s.source }}</td>
                    <td data-col="received">{{ s.received }}</td>
                    <td data-col="interviewed">{{ s.interviewed }}</td>
                    <td data-col="hired">{{ s.hired }}</td>
                    <td>{{ conversion(s.interviewed, s.received) }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div class="card section">
            <div class="card-head">
              <div>
                <h2>Needs attention</h2>
                <p>Across the company's open roles right now.</p>
              </div>
            </div>
            <div class="attention-list">
              <div v-for="t in attentionTiles" :key="t.label" class="attention">
                <div>
                  <strong>{{ t.label }}</strong>
                  <small>{{ t.hint }}</small>
                </div>
                <span class="kpi-value" :class="{ warn: t.value > 0 }">{{ t.value }}</span>
              </div>
            </div>
          </div>
        </div>

        <RecruitmentTiming :company-id="companyId" :from="range.from" :to="range.to" />
      </div>
    </template>
  </div>
</template>

<style scoped>
.page-head { margin-bottom: 20px; }
.page-sub { margin: 0; font-size: 12px; color: var(--muted); }
.controls { display: flex; gap: 14px; align-items: flex-end; flex-wrap: wrap; padding: 16px 20px; margin-bottom: 20px; }
.controls .field { margin: 0; min-width: 160px; }
.controls .button { margin-left: auto; }
.report-ready.dim { opacity: 0.6; }
.inline-warning { margin: -8px 0 16px; font-size: 12px; color: var(--amber); }
.kpis { display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; margin-bottom: 20px; }
@media (max-width: 960px) { .kpis { grid-template-columns: repeat(2, 1fr); } }
.kpi { display: flex; flex-direction: column; gap: 8px; padding: 16px 18px; }
.kpi-label { font-size: 11px; color: var(--muted); font-weight: 550; }
.kpi-value { font-size: 24px; font-weight: 750; letter-spacing: -0.02em; }
.section { margin-bottom: 20px; }
.two-up { display: grid; grid-template-columns: 3fr 2fr; gap: 20px; }
@media (max-width: 960px) { .two-up { grid-template-columns: 1fr; } }
.job-link { color: inherit; text-decoration: none; font-weight: 550; }
.job-link:hover { color: var(--green); text-decoration: underline; }
.attention-list { padding: 6px 0; }
.attention { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 13px 24px; border-top: 1px solid #edf0eb; }
.attention strong { display: block; font-size: 12px; font-weight: 550; }
.attention small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.attention .kpi-value { font-size: 20px; }
.attention .warn { color: var(--amber); }
</style>
