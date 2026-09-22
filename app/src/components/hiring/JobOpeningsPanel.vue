<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import CompanyFilter from '@/components/CompanyFilter.vue'
import { openingRows, type JobOpeningRow, type OpeningApplicationLite, JOB_STATUS_LABEL } from '@/lib/hiringTabs'

/**
 * The prototype's "Job openings" tab (plan 044): every job the viewer may
 * see, its status, headcount from the request, live applicants, and the
 * hiring manager — with a company filter and a status filter. Open a row
 * to work the job.
 */
type JobRow = {
  id: string
  title: string
  status: string
  company_id: string
  created_at: string
  company: { name: string } | null
  request: { headcount: number; manager: { full_name: string } | null } | null
}

const loading = ref(true)
const error = ref<string | null>(null)
const jobs = ref<JobRow[]>([])
const applications = ref<OpeningApplicationLite[]>([])
const companyId = ref('')
const status = ref<'live' | 'all' | string>('live')

const companies = computed(() => {
  const seen = new Map<string, string>()
  jobs.value.forEach((j) => seen.set(j.company_id, j.company?.name ?? '—'))
  return [...seen].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name))
})
const rows = computed<JobOpeningRow[]>(() => openingRows(jobs.value, applications.value, { companyId: companyId.value, status: status.value }))

// PostgREST answers at most 1,000 rows per request; since the Zoho import
// (0067) the holding carries several thousand applications, so one plain
// select silently dropped the newest and every "in play" read low. Only the
// rows that count are asked for (rejected / withdrawn count nowhere), in
// pages, in id order so a page boundary never skips or repeats a row.
const PAGE = 1000

async function loadCountedApplications(): Promise<{ data: OpeningApplicationLite[]; error: { message: string } | null }> {
  const rows: OpeningApplicationLite[] = []
  for (let from = 0; ; from += PAGE) {
    const { data, error: err } = await supabase
      .from('applications')
      .select('id, job_id, stage_key')
      .not('stage_key', 'in', '(rejected,withdrawn)')
      .order('id')
      .range(from, from + PAGE - 1)
    if (err) return { data: [], error: err }
    rows.push(...((data ?? []) as OpeningApplicationLite[]))
    if ((data ?? []).length < PAGE) return { data: rows, error: null }
  }
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [jobsRes, appsRes] = await Promise.all([
    supabase
      .from('jobs')
      .select('id, title, status, company_id, created_at, company:companies(name), request:hiring_requests!jobs_hiring_request_id_fkey(headcount, manager:people!hiring_requests_hiring_manager_id_fkey(full_name))')
      .order('created_at', { ascending: false }),
    loadCountedApplications(),
  ])
  loading.value = false
  if (jobsRes.error || appsRes.error) {
    error.value = 'Could not load the job openings.'
    console.error('Job openings load failed:', jobsRes.error?.message ?? appsRes.error?.message)
    return
  }
  jobs.value = (jobsRes.data ?? []) as unknown as JobRow[]
  applications.value = appsRes.data
}

onMounted(load)
</script>

<template>
  <div class="card" data-testid="job-openings">
    <div class="card-head">
      <div>
        <h2>Job openings</h2>
        <p>Every role being hired, with who is in play. Prepared from an approved request.</p>
      </div>
      <div class="filters">
        <CompanyFilter v-model="companyId" :companies="companies" all-label="All companies" />
        <label class="status-filter">
          <select v-model="status" aria-label="Status">
            <option value="live">Live (ready, open, on hold)</option>
            <option value="all">All statuses</option>
            <option v-for="(label, key) in JOB_STATUS_LABEL" :key="key" :value="key">{{ label }}</option>
          </select>
        </label>
      </div>
    </div>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
    <div v-else-if="loading" class="empty">Loading job openings…</div>
    <div v-else-if="!rows.length" class="empty">No job openings match. Approve a hiring request and prepare its job to start one.</div>
    <div v-else class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Role</th>
            <th>Company</th>
            <th>Status</th>
            <th class="num">Needed</th>
            <th class="num">In play</th>
            <th class="num">Hired</th>
            <th>Hiring manager</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.id" :data-testid="`opening-${r.id}`">
            <td><b>{{ r.title }}</b></td>
            <td>{{ r.company }}</td>
            <td><span class="badge" :class="r.statusTone">{{ r.statusLabel }}</span></td>
            <td class="num">{{ r.headcount }}</td>
            <td class="num">{{ r.inPlay }}</td>
            <td class="num">{{ r.hired }}</td>
            <td>{{ r.manager ?? '—' }}</td>
            <td class="actions"><router-link class="button secondary small-btn" :to="{ name: 'job', params: { jobId: r.id } }">Open job</router-link></td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<style scoped>
.filters { display: flex; gap: 10px; flex-wrap: wrap; align-items: end; }
.status-filter select { border: 1px solid var(--line); background: #fff; padding: 8px 10px; font-size: 12px; color: var(--ink); min-width: 180px; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { text-align: left; font-size: 11px; font-weight: 550; color: var(--muted); padding: 10px 24px; border-bottom: 1px solid var(--line); }
td { padding: 12px 24px; border-bottom: 1px solid var(--line); vertical-align: middle; }
td b { font-weight: 600; }
.num { text-align: right; font-variant-numeric: tabular-nums; }
.actions { text-align: right; white-space: nowrap; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
