<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import CompanyFilter from '@/components/CompanyFilter.vue'
import { PIPELINE_STAGES } from '@/lib/dashboard'
import { applicantRows, type ApplicantLite, type ApplicantRow } from '@/lib/hiringTabs'

/**
 * The prototype's "Applicants" tab (plan 044): every application across
 * every job the viewer may see, newest first, with company, stage and a
 * search over name, position and email. Adding a candidate stays on the
 * job (a candidate always applies to a role) — "Open job" takes you there.
 */
const loading = ref(true)
const error = ref<string | null>(null)
const applications = ref<ApplicantLite[]>([])
const companyId = ref('')
const stage = ref('live')
const search = ref('')

const companies = computed(() => {
  const seen = new Map<string, string>()
  applications.value.forEach((a) => seen.set(a.company_id, a.job?.company?.name ?? '—'))
  return [...seen].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name))
})
const rows = computed<ApplicantRow[]>(() => applicantRows(applications.value, { companyId: companyId.value, stage: stage.value, search: search.value }))

function badgeClass(stageKey: string): string {
  if (stageKey === 'hired') return 'green'
  if (stageKey === 'offer' || stageKey === 'interview') return 'amber'
  if (stageKey === 'rejected' || stageKey === 'withdrawn') return ''
  return 'blue'
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('applications')
    .select(
      'id, company_id, stage_key, received_at, next_action, next_action_due, candidate:candidates(full_name, email), job:jobs(id, title, company:companies(name)), owner:people!applications_owner_id_fkey(full_name)',
    )
    .order('received_at', { ascending: false })
  loading.value = false
  if (err) {
    error.value = 'Could not load the applicants.'
    console.error('Applicants load failed:', err.message)
    return
  }
  applications.value = (data ?? []) as unknown as ApplicantLite[]
}

onMounted(load)
</script>

<template>
  <div class="card" data-testid="applicants">
    <div class="card-head">
      <div>
        <h2>Applicants</h2>
        <p>Everyone in a pipeline, wherever they applied. Open a candidate to move them on.</p>
      </div>
      <div class="filters">
        <input v-model="search" class="search" type="search" placeholder="Search name, role, email" aria-label="Search applicants" />
        <CompanyFilter v-model="companyId" :companies="companies" all-label="All companies" />
        <label class="stage-filter">
          <select v-model="stage" aria-label="Stage">
            <option value="live">In progress</option>
            <option value="all">All stages</option>
            <option v-for="s in PIPELINE_STAGES" :key="s.key" :value="s.key">{{ s.label }}</option>
            <option value="withdrawn">Withdrawn</option>
          </select>
        </label>
      </div>
    </div>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
    <div v-else-if="loading" class="empty">Loading applicants…</div>
    <div v-else-if="!rows.length" class="empty">No applicants match. Add candidates or upload CVs from a job.</div>
    <div v-else class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Candidate</th>
            <th>Position</th>
            <th>Company</th>
            <th>Stage</th>
            <th>Applied</th>
            <th>Owner · next step</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.id" :data-testid="`applicant-${r.id}`">
            <td><b>{{ r.name }}</b><small v-if="r.email" class="sub">{{ r.email }}</small></td>
            <td>{{ r.position }}</td>
            <td>{{ r.company }}</td>
            <td><span class="badge" :class="badgeClass(r.stage)">{{ r.stageLabel }}</span></td>
            <td>{{ r.received }}</td>
            <td>{{ r.owner ?? 'Unassigned' }}<small v-if="r.nextAction" class="sub">{{ r.nextAction }}</small></td>
            <td class="actions">
              <div class="action-group">
                <router-link class="button secondary small-btn" :to="{ name: 'application', params: { applicationId: r.id } }">Open candidate</router-link>
                <router-link v-if="r.jobId" class="button secondary small-btn" :to="{ name: 'job', params: { jobId: r.jobId }, query: { tab: 'applications' } }">Open job</router-link>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<style scoped>
.filters { display: flex; gap: 10px; flex-wrap: wrap; align-items: end; }
.search, .stage-filter select { border: 1px solid var(--line); background: #fff; padding: 8px 10px; font-size: 12px; color: var(--ink); min-width: 180px; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { text-align: left; font-size: 11px; font-weight: 550; color: var(--muted); padding: 10px 24px; border-bottom: 1px solid var(--line); }
td { padding: 12px 24px; border-bottom: 1px solid var(--line); vertical-align: middle; }
td b { font-weight: 600; }
.sub { display: block; font-size: 11px; color: var(--muted); margin-top: 2px; }
.actions { text-align: right; white-space: nowrap; }
.action-group { display: inline-flex; gap: 6px; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
