<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import CompanyFilter from '@/components/CompanyFilter.vue'
import { PIPELINE_STAGES } from '@/lib/dashboard'
import { NOT_RESPONDING_FILTER, applicantRows, type ApplicantLite, type ApplicantRow } from '@/lib/hiringTabs'
import { SUB_STATUS_STAGES, subStatusesFor, type SubStatusRow } from '@/lib/outreach'
import { blockerCount, blockerWords, friendlyHardDeleteError } from '@/lib/hardDelete'
import { FILE_BUCKET } from '@/lib/applicationFiles'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'

/**
 * The prototype's "Applicants" tab (plan 044): every application across
 * every job the viewer may see, newest first, with company, stage and a
 * search over name, position and email. Adding a candidate stays on the
 * job (a candidate always applies to a role) — "Open job" takes you there.
 * The stage filter travels to the query and the list is capped (plan 052):
 * PostgREST would otherwise cut the imported history at 1,000 rows silently.
 * Since plan 054 the stage cell carries the sub-status and "Not responding",
 * judged over the loaded rows from the candidate's last activity (see
 * outreachRowOf); "Not responding" in the stage filter is that judgement
 * over the New and Screening rows.
 */
const PAGE_CAP = 1000
const CLOSED_STAGES = '(hired,rejected,withdrawn)'
const CAPPED_NOTICE = 'Showing the newest 1,000 — narrow the filters to see older ones.'

const loading = ref(true)
const auth = useAuthStore()
const dialogs = useDialogStore()
const error = ref<string | null>(null)
const busyId = ref<string | null>(null)
const applications = ref<ApplicantLite[]>([])
const subStatusRows = ref<SubStatusRow[]>([])
const subStatusLabels = computed<Record<string, string>>(() =>
  Object.fromEntries(SUB_STATUS_STAGES.flatMap((stage) => subStatusesFor(subStatusRows.value, stage)).map((s) => [s.key, s.label])),
)
const companyId = ref('')
const stage = ref('live')
const search = ref('')
const capped = computed(() => applications.value.length === PAGE_CAP)

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

/**
 * Delete a mistaken or test application from the list somebody is looking at
 * (plan 063). `delete_job_application` (0081) is the rule: it refuses files,
 * interviews and offers, takes the stage history with it, and leaves the
 * candidate and any employment record alone.
 */
async function removeApplication(r: ApplicantRow): Promise<void> {
  // Attached records are not a wall, only a question asked properly: the
  // confirmation names what goes, because nothing else in the app can remove
  // an offer or an interview once it exists (0082).
  const force = blockerCount(r.blockers) > 0
  const ok = await dialogs.confirmAction({
    title: `Delete ${r.name}'s application?`,
    hint: force
      ? `${r.position} at ${r.company}. This one also has ${blockerWords(r.blockers)}, and they go with it. ${r.name} stays in the talent pool. This cannot be undone.`
      : `${r.position} at ${r.company}. The application and its history go; ${r.name} stays in the talent pool. This cannot be undone.`,
    confirmLabel: force ? 'Delete it and everything on it' : 'Delete application',
    danger: true,
  })
  if (!ok) return
  error.value = null
  busyId.value = r.id
  const { data, error: err } = await supabase.rpc('delete_job_application', {
    p_application_id: r.id,
    p_force: force,
  })
  busyId.value = null
  if (err) {
    error.value = friendlyHardDeleteError(err.message)
    return
  }
  // The files' objects outlive their rows; only the app can reach Storage.
  const paths = ((data ?? {}) as { storage_paths?: string[] }).storage_paths ?? []
  if (paths.length) {
    const { error: fileErr } = await supabase.storage.from(FILE_BUCKET).remove(paths)
    if (fileErr) console.error('Application files not removed:', fileErr.message)
  }
  await load()
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const stageKey = stage.value
  let query = supabase
    .from('applications')
    .select(
      `id, company_id, stage_key, sub_status_key, received_at, next_action, next_action_due,
       application_files(count), interviews(count), offers(count),
       candidate:candidates(full_name, email, last_activity_at),
       job:jobs(id, title, status, company:companies(name)),
       owner:people!applications_owner_id_fkey(full_name)`,
    )
  if (stageKey === 'live') query = query.not('stage_key', 'in', CLOSED_STAGES)
  else if (stageKey === NOT_RESPONDING_FILTER) query = query.in('stage_key', [...SUB_STATUS_STAGES])
  else if (stageKey !== 'all') query = query.eq('stage_key', stageKey)
  const { data, error: err } = await query.order('received_at', { ascending: false }).limit(PAGE_CAP)
  loading.value = false
  if (err) {
    error.value = 'Could not load the applicants.'
    console.error('Applicants load failed:', err.message)
    return
  }
  applications.value = (data ?? []) as unknown as ApplicantLite[]
}

async function loadSubStatuses(): Promise<void> {
  const { data, error: err } = await supabase
    .from('application_sub_statuses')
    .select('key, stage_key, label, sort_order, archived_at')
    .is('archived_at', null)
    .order('sort_order')
  if (err) {
    console.error('Sub-statuses load failed:', err.message)
    return
  }
  subStatusRows.value = data ?? []
}

onMounted(() => {
  void loadSubStatuses()
  void load()
})
watch(stage, load)
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
            <option :value="NOT_RESPONDING_FILTER">Not responding</option>
          </select>
        </label>
      </div>
    </div>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
    <div v-else-if="loading" class="empty">Loading applicants…</div>
    <div v-else-if="!rows.length" class="empty">No applicants match. Add candidates or upload CVs from a job.</div>
    <div v-else class="table-wrap">
      <p v-if="capped" class="capped-note" role="status" data-testid="applicants-capped">{{ CAPPED_NOTICE }}</p>
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
            <td>
              <span class="badge" :class="badgeClass(r.stage)">{{ r.stageLabel }}</span>
              <small v-if="r.subStatusKey && subStatusLabels[r.subStatusKey]" class="sub" data-testid="sub-badge">{{ subStatusLabels[r.subStatusKey] }}</small>
              <span v-if="r.notResponding" class="sub-badge amber" data-testid="not-responding-badge">Not responding</span>
            </td>
            <td>{{ r.received }}</td>
            <td>{{ r.owner ?? 'Unassigned' }}<small v-if="r.nextAction" class="sub">{{ r.nextAction }}</small></td>
            <td class="actions">
              <div class="action-group">
                <router-link class="button secondary small-btn" :to="{ name: 'application', params: { applicationId: r.id } }">Open candidate</router-link>
                <router-link v-if="r.jobId" class="button secondary small-btn" :to="{ name: 'job', params: { jobId: r.jobId }, query: { tab: 'applications' } }">Open job</router-link>
                <button
                  v-if="auth.can(r.companyId, 'candidates.review')"
                  class="button secondary small-btn danger-text"
                  type="button"
                  :disabled="busyId === r.id"
                  :title="blockerCount(r.blockers) > 0
                    ? `Also deletes ${blockerWords(r.blockers)}. The candidate stays.`
                    : 'Deletes the application and its stage history. The candidate and any employment record stay.'"
                  :data-testid="`delete-application-${r.id}`"
                  @click="removeApplication(r)"
                >
                  Delete
                </button>
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
.capped-note { margin: 0; padding: 10px 24px; font-size: 12px; color: var(--muted); background: #fafbf9; border-bottom: 1px solid var(--line); }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { text-align: left; font-size: 11px; font-weight: 550; color: var(--muted); padding: 10px 24px; border-bottom: 1px solid var(--line); }
td { padding: 12px 24px; border-bottom: 1px solid var(--line); vertical-align: middle; }
td b { font-weight: 600; }
.sub { display: block; font-size: 11px; color: var(--muted); margin-top: 2px; }
.sub-badge { display: inline-flex; align-items: center; margin-top: 4px; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 550; white-space: nowrap; }
.sub-badge.amber { background: #fbf1da; color: var(--amber); }
.actions { text-align: right; white-space: nowrap; }
.action-group { display: inline-flex; gap: 6px; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
