<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import CompanyFilter from '@/components/CompanyFilter.vue'
import CloseJobsDialog from '@/components/hiring/CloseJobsDialog.vue'
import { openingRows, type JobOpeningRow, type OpeningApplicationLite, JOB_STATUS_LABEL } from '@/lib/hiringTabs'
import { pageAll } from '@/lib/pageAll'
import { closeSummary, friendlyCloseError, whyNotSelectable, type CloseOutcome, type CloseTarget } from '@/lib/closeJobs'
import { friendlyDeleteError, jobDeletable } from '@/lib/hiringDelete'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'

/**
 * The prototype's "Job openings" tab (plan 044): every job the viewer may
 * see, its status, headcount from the request, live applicants, and the
 * hiring manager — with a company filter and a status filter. Open a row
 * to work the job.
 *
 * Plan 056 made this the place the backlog is swept: pick rows, close them,
 * and — the maintainer's "abandon" — withdraw the candidates still waiting on
 * them in the same act, so a closed opening stops counting people nobody will
 * answer. Deleting stays what the database allows: a job nobody ever applied
 * to, and the disabled button says why when that is not the case.
 */
type JobRow = {
  id: string
  title: string
  status: string
  company_id: string
  created_at: string
  closed_at: string | null
  closed_reason: string | null
  company: { name: string } | null
  closed_by_person: { full_name: string } | null
  request: { headcount: number; manager: { full_name: string } | null } | null
  applications: { count: number }[] | null
}

const auth = useAuthStore()
const dialogs = useDialogStore()

const loading = ref(true)
const error = ref<string | null>(null)
const jobs = ref<JobRow[]>([])
const applications = ref<OpeningApplicationLite[]>([])
const companyId = ref('')
const status = ref<'live' | 'all' | string>('live')

const selected = ref<ReadonlySet<string>>(new Set())
const closeDialog = ref<InstanceType<typeof CloseJobsDialog> | null>(null)
const busy = ref(false)
const actionError = ref<string | null>(null)
const notice = ref<string | null>(null)

const companies = computed(() => {
  const seen = new Map<string, string>()
  jobs.value.forEach((j) => seen.set(j.company_id, j.company?.name ?? '—'))
  return [...seen].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name))
})
const rows = computed<JobOpeningRow[]>(() => openingRows(jobs.value, applications.value, { companyId: companyId.value, status: status.value }))

/** A row as the closing dialog and its rules see it. */
function target(r: JobOpeningRow): CloseTarget {
  return {
    id: r.id,
    title: r.title,
    company: r.company,
    status: r.status,
    inPlay: r.inPlay,
    mayEdit: auth.can(r.companyId, 'jobs.edit'),
    // close_jobs demands this of every company in the call before it will
    // withdraw anybody, so the dialog must know it before offering to.
    mayWithdraw: auth.can(r.companyId, 'candidates.review'),
  }
}
const selectable = computed(() => rows.value.filter((r) => whyNotSelectable(target(r)) === null))
const picked = computed(() => rows.value.filter((r) => selected.value.has(r.id)))
const allPicked = computed(() => selectable.value.length > 0 && selectable.value.every((r) => selected.value.has(r.id)))

/** Why this row's checkbox is off, for its title attribute. */
function selectionBlock(r: JobOpeningRow): string | null {
  return whyNotSelectable(target(r))
}

function toggle(id: string, on: boolean): void {
  const next = new Set(selected.value)
  if (on) next.add(id)
  else next.delete(id)
  selected.value = next
}

function toggleAll(on: boolean): void {
  selected.value = on ? new Set(selectable.value.map((r) => r.id)) : new Set()
}

// The rows behind a selection change when the filters do, so the selection
// goes with them rather than acting on jobs nobody can see any more.
watch([companyId, status], () => {
  selected.value = new Set()
})

/**
 * The count behind the delete rule is read under the viewer's own visibility:
 * without `candidates.view` here, every job would report zero applications
 * and the button would promise that nothing was ever received. So the rule is
 * only applied by somebody who can actually see what came in.
 */
function deleteVerdict(r: JobOpeningRow) {
  return jobDeletable(
    { applications: r.applications },
    auth.can(r.companyId, 'jobs.edit'),
    auth.can(r.companyId, 'candidates.view'),
  )
}

function askToClose(): void {
  if (!picked.value.length) return
  actionError.value = null
  notice.value = null
  closeDialog.value?.open(picked.value.map(target))
}

async function runClose(payload: { reason: string; withdraw: boolean }): Promise<void> {
  busy.value = true
  actionError.value = null
  notice.value = null
  const ids = picked.value.map((r) => r.id)
  const { data, error: err } = await supabase.rpc('close_jobs', {
    p_job_ids: ids,
    p_reason: payload.reason || undefined,
    p_withdraw: payload.withdraw,
  })
  busy.value = false
  if (err) {
    actionError.value = friendlyCloseError(err.message)
    return
  }
  notice.value = closeSummary(data as unknown as CloseOutcome)
  selected.value = new Set()
  await load()
}

async function removeJob(r: JobOpeningRow): Promise<void> {
  const verdict = deleteVerdict(r)
  if (!verdict.canDelete) return
  const ok = await dialogs.confirmAction({
    title: `Delete ${r.title}?`,
    hint: 'Nothing was ever received for this opening, so nothing is lost. It cannot be undone.',
    confirmLabel: 'Delete job',
    danger: true,
  })
  if (!ok) return

  busy.value = true
  actionError.value = null
  notice.value = null
  const { error: err } = await supabase.from('jobs').delete().eq('id', r.id)
  busy.value = false
  if (err) {
    actionError.value = friendlyDeleteError(err.message)
    return
  }
  notice.value = `${r.title} deleted.`
  toggle(r.id, false)
  await load()
}

// PostgREST answers at most 1,000 rows per request; since the Zoho import
// (0067) the holding carries several thousand applications, so one plain
// select silently dropped the newest and every "in play" read low. Only the
// rows that count are asked for (rejected / withdrawn count nowhere), in
// pages, in id order so a page boundary never skips or repeats a row. The
// total per job — the rule for deleting — comes from the jobs query instead,
// counted in the database, so this stays the smaller read.
function loadCountedApplications(): Promise<{ data: OpeningApplicationLite[]; error: { message: string } | null }> {
  return pageAll<OpeningApplicationLite>((from, to) =>
    supabase
      .from('applications')
      .select('id, job_id, stage_key')
      .not('stage_key', 'in', '(rejected,withdrawn)')
      .order('id')
      .range(from, to),
  )
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [jobsRes, appsRes] = await Promise.all([
    supabase
      .from('jobs')
      .select(
        `id, title, status, company_id, created_at, closed_at, closed_reason,
         company:companies(name), closed_by_person:people!jobs_closed_by_fkey(full_name),
         request:hiring_requests!jobs_hiring_request_id_fkey(headcount, manager:people!hiring_requests_hiring_manager_id_fkey(full_name)),
         applications(count)`,
      )
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
        <button
          v-if="picked.length"
          class="button secondary small-btn"
          type="button"
          :disabled="busy"
          data-testid="close-selected"
          @click="askToClose"
        >
          Close {{ picked.length }} selected
        </button>
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
    <template v-else>
      <p v-if="actionError" class="error-note" role="alert" style="margin: 16px 24px" data-testid="openings-error">{{ actionError }}</p>
      <p v-if="notice" class="notice" role="status" data-testid="openings-notice">{{ notice }}</p>
      <div v-if="loading" class="empty">Loading job openings…</div>
      <div v-else-if="!rows.length" class="empty">No job openings match. Approve a hiring request and prepare its job to start one.</div>
      <div v-else class="table-wrap">
        <table>
          <thead>
            <tr>
              <th class="pick">
                <input
                  type="checkbox"
                  :checked="allPicked"
                  :disabled="!selectable.length"
                  aria-label="Select every opening listed"
                  data-testid="select-all-openings"
                  @change="toggleAll(($event.target as HTMLInputElement).checked)"
                />
              </th>
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
              <td class="pick">
                <input
                  type="checkbox"
                  :checked="selected.has(r.id)"
                  :disabled="!!selectionBlock(r) || busy"
                  :title="selectionBlock(r) ?? undefined"
                  :aria-label="`Select ${r.title}`"
                  :data-testid="`pick-${r.id}`"
                  @change="toggle(r.id, ($event.target as HTMLInputElement).checked)"
                />
              </td>
              <td><b>{{ r.title }}</b></td>
              <td>{{ r.company }}</td>
              <td>
                <span class="badge" :class="r.statusTone">{{ r.statusLabel }}</span>
                <small v-if="r.closedLine" class="closed-line" :data-testid="`closed-${r.id}`">
                  {{ r.closedLine }}<template v-if="r.closedReason"> · {{ r.closedReason }}</template>
                </small>
              </td>
              <td class="num">{{ r.headcount }}</td>
              <td class="num">{{ r.inPlay }}</td>
              <td class="num">{{ r.hired }}</td>
              <td>{{ r.manager ?? '—' }}</td>
              <td class="actions">
                <router-link class="button secondary small-btn" :to="{ name: 'job', params: { jobId: r.id } }">Open job</router-link>
                <button
                  class="button secondary small-btn danger-text"
                  type="button"
                  :disabled="!deleteVerdict(r).canDelete || busy"
                  :title="deleteVerdict(r).reason ?? undefined"
                  :data-testid="`delete-${r.id}`"
                  @click="removeJob(r)"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
    <CloseJobsDialog ref="closeDialog" @confirmed="runClose" />
  </div>
</template>

<style scoped>
.filters { display: flex; gap: 10px; flex-wrap: wrap; align-items: end; }
.status-filter select { border: 1px solid var(--line); background: #fff; padding: 8px 10px; font-size: 12px; color: var(--ink); min-width: 180px; }
.notice { margin: 16px 24px 0; font-size: 12px; color: var(--muted); }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { text-align: left; font-size: 11px; font-weight: 550; color: var(--muted); padding: 10px 24px; border-bottom: 1px solid var(--line); }
td { padding: 12px 24px; border-bottom: 1px solid var(--line); vertical-align: middle; }
td b { font-weight: 600; }
.pick { width: 1%; padding-right: 0; }
.pick input { width: 15px; height: 15px; }
.closed-line { display: block; margin-top: 4px; color: var(--muted); font-size: 11px; line-height: 1.5; max-width: 34ch; }
.num { text-align: right; font-variant-numeric: tabular-nums; }
.actions { text-align: right; white-space: nowrap; display: flex; gap: 6px; justify-content: flex-end; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.danger-text:not(:disabled) { color: var(--red); }
</style>
