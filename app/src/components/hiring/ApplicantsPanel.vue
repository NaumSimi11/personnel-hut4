<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { supabase } from '@/lib/supabase'
import CompanyFilter from '@/components/CompanyFilter.vue'
import { PIPELINE_STAGES } from '@/lib/dashboard'
import { applicantRows, type ApplicantLite, type ApplicantRow } from '@/lib/hiringTabs'
import type { SubStatusRow } from '@/lib/outreach'
import { NOT_RESPONDING_FILTER, filterStagesFor, statusFilterGroups, statusLabels } from '@/lib/stageStatuses'
import { blockerCount, blockerWords, friendlyHardDeleteError } from '@/lib/hardDelete'
import { FILE_BUCKET } from '@/lib/applicationFiles'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { useHiringLookupsStore } from '@/stores/hiringLookups'
import { LIST_PAGE } from '@/lib/pageAll'
import { likePattern } from '@/lib/likePattern'
import { createRequestGate } from '@/lib/requestGate'
import { applicantsQueryPlan, orderNewestFirst } from '@/lib/applicationQueries'

/**
 * The prototype's "Applicants" tab (plan 044): every application across
 * every job the viewer may see, newest first, with company, stage and a
 * search over name, position and email. Adding a candidate stays on the
 * job (a candidate always applies to a role) — "Open job" takes you there.
 * The stage filter and the name search travel to the query, and the list
 * loads LIST_PAGE rows at a time with "Load more" (egress: never the whole
 * imported history in one read).
 * Since plan 054 the stage cell carries the sub-status and "Not responding",
 * judged over the loaded rows from the candidate's last activity (see
 * outreachRowOf); "Not responding" in the stage filter is that judgement
 * over the New and Screening rows. Since plan 068 every stage has statuses:
 * the badge names a retired one too, and the status filter travels to the
 * query like the stage filter, narrowed to the chosen stage's statuses.
 * `?stage=` and `?status=` open the list already filtered — the Labels
 * page's "Review them first" (plan 069) links here that way. Since plan 075
 * "In progress" is `in_play`, a stage holds everyone who reached it, and a
 * row its job's closing marked says so where its status would be. The
 * company filter and "Not responding" run in the query too: the latter is
 * the database's rule (not_responding_applications, the one Home counts),
 * so the list, its badge and "Showing N of total" agree with the filter.
 */
const SEARCH_DEBOUNCE_MS = 300

const loading = ref(true)
const auth = useAuthStore()
const dialogs = useDialogStore()
const error = ref<string | null>(null)
const busyId = ref<string | null>(null)
const applications = ref<ApplicantLite[]>([])
const lookups = useHiringLookupsStore()
const subStatusRows = computed<SubStatusRow[]>(() => lookups.statuses)
const total = ref(0)
const loadingMore = ref(false)
const subStatusLabels = computed<Record<string, string>>(() => statusLabels(subStatusRows.value))
const route = useRoute()
const STAGE_FILTERS = new Set<string>(['live', 'all', NOT_RESPONDING_FILTER, ...PIPELINE_STAGES.map((s) => s.key)])
function queryText(name: string): string {
  const raw = route.query[name]
  return typeof raw === 'string' ? raw : ''
}
const companyId = ref('')
const stage = ref(STAGE_FILTERS.has(queryText('stage')) ? queryText('stage') : 'live')
const status = ref(queryText('status'))
const statusGroups = computed(() => statusFilterGroups(subStatusRows.value, filterStagesFor(stage.value)))
const search = ref('')
const hasMore = computed(() => applications.value.length < total.value)

const companies = ref<{ id: string; name: string }[]>([])
// The query already filtered; the rows only take their shape here. Every row
// the "Not responding" filter returned is flagged by the database's rule.
const rows = computed<ApplicantRow[]>(() => {
  const shaped = applicantRows(applications.value, { companyId: '', stage: 'all', search: '' })
  return stage.value === NOT_RESPONDING_FILTER ? shaped.map((r) => ({ ...r, notResponding: true })) : shaped
})

/** The companies the viewer may see candidates in (a handful of rows, once). */
async function loadCompanies(): Promise<void> {
  const { data, error: err } = await supabase.from('companies').select('id, name').is('archived_at', null).order('name')
  if (err) {
    console.error('Companies load failed:', err.message)
    return
  }
  companies.value = (data ?? []).filter((c) => auth.can(c.id, 'candidates.view'))
}

function badgeClass(stageKey: string, inPlay: boolean): string {
  if (stageKey === 'hired') return 'green'
  if (!inPlay) return ''
  if (stageKey === 'offer' || stageKey === 'interview') return 'amber'
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

const COLUMNS = `id, company_id, stage_key, sub_status_key, in_play, closed_at, closed_reason, received_at, next_action, next_action_due,
       application_files(count), interviews(count), offers(count),
       candidate:candidates!inner(full_name, email, last_activity_at),
       job:jobs(id, title, status, company:companies(name)),
       owner:people!applications_owner_id_fkey(full_name)`

/** One window of the list; the stage, status, company and name filters all run in the query. */
function fetchPage(from: number) {
  const plan = applicantsQueryPlan({ stage: stage.value, status: status.value, companyId: companyId.value, search: search.value })
  let query = plan.notResponding
    ? supabase.rpc('not_responding_applications', {}, { count: 'exact' }).select(COLUMNS)
    : supabase.from('applications').select(COLUMNS, { count: 'exact' })
  for (const [column, value] of plan.eq) query = query.eq(column, value)
  if (plan.nameLike) query = query.ilike('candidate.full_name', likePattern(plan.nameLike))
  return orderNewestFirst(query).range(from, from + LIST_PAGE - 1)
}

// A newer load (or a filter change) retires the answers still on the way.
const gate = createRequestGate()

async function load(): Promise<void> {
  const ticket = gate.next()
  loading.value = true
  loadingMore.value = false
  error.value = null
  const { data, count, error: err } = await fetchPage(0)
  if (!gate.isCurrent(ticket)) return
  loading.value = false
  if (err) {
    error.value = 'Could not load the applicants.'
    console.error('Applicants load failed:', err.message)
    return
  }
  applications.value = (data ?? []) as unknown as ApplicantLite[]
  total.value = count ?? applications.value.length
}

async function loadMore(): Promise<void> {
  if (loading.value || loadingMore.value || !hasMore.value) return
  const ticket = gate.snapshot()
  loadingMore.value = true
  const { data, count, error: err } = await fetchPage(applications.value.length)
  if (!gate.isCurrent(ticket)) return
  loadingMore.value = false
  if (err) {
    error.value = 'Could not load more applicants.'
    console.error('Applicants load-more failed:', err.message)
    return
  }
  applications.value = [...applications.value, ...((data ?? []) as unknown as ApplicantLite[])]
  total.value = count ?? total.value
}

let searchTimer: ReturnType<typeof setTimeout> | null = null
watch(search, () => {
  if (searchTimer) clearTimeout(searchTimer)
  searchTimer = setTimeout(() => void load(), SEARCH_DEBOUNCE_MS)
})
onBeforeUnmount(() => {
  if (searchTimer) clearTimeout(searchTimer)
})

onMounted(() => {
  void lookups.ensure()
  void loadCompanies()
  void load()
})
// A status of another stage cannot match: clearing it reloads through its own watcher.
watch(stage, () => {
  const fits = statusGroups.value.some((g) => g.options.some((o) => o.key === status.value))
  if (status.value && !fits) status.value = ''
  else void load()
})
watch(status, load)
watch(companyId, load)
</script>

<template>
  <div class="card" data-testid="applicants">
    <div class="card-head">
      <div>
        <h2>Applicants</h2>
        <p>Everyone in a pipeline, wherever they applied. Open a candidate to move them on.</p>
      </div>
      <div class="filters">
        <input v-model="search" class="search" type="search" placeholder="Search name" aria-label="Search applicants" />
        <CompanyFilter v-model="companyId" :companies="companies" all-label="All companies" />
        <label class="stage-filter">
          <select v-model="stage" aria-label="Stage">
            <option value="live">In progress</option>
            <option value="all">All stages</option>
            <option v-for="s in PIPELINE_STAGES" :key="s.key" :value="s.key">{{ s.label }}</option>
            <option :value="NOT_RESPONDING_FILTER">Not responding</option>
          </select>
        </label>
        <label class="stage-filter">
          <select v-model="status" aria-label="Status" data-testid="applicants-status-filter">
            <option value="">Any status</option>
            <optgroup v-for="g in statusGroups" :key="g.stageKey" :label="g.stageLabel">
              <option v-for="o in g.options" :key="o.key" :value="o.key">{{ o.label }}</option>
            </optgroup>
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
            <td>
              <span class="badge" :class="badgeClass(r.stage, r.inPlay)">{{ r.stageLabel }}</span>
              <small v-if="r.closure" class="sub" data-testid="closure-badge">{{ r.closure }}</small>
              <small v-else-if="r.subStatusKey && subStatusLabels[r.subStatusKey]" class="sub" data-testid="sub-badge">{{ subStatusLabels[r.subStatusKey] }}</small>
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
      <div v-if="hasMore" class="load-more">
        <span>Showing {{ applications.length }} of {{ total }}</span>
        <button class="button secondary" type="button" :disabled="loadingMore" data-testid="applicants-load-more" @click="loadMore">
          {{ loadingMore ? 'Loading…' : 'Load more' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.filters { display: flex; gap: 10px; flex-wrap: wrap; align-items: end; }
.search, .stage-filter select { border: 1px solid var(--line); background: #fff; padding: 8px 10px; font-size: 12px; color: var(--ink); min-width: 180px; }
.load-more { display: flex; align-items: center; justify-content: center; gap: 12px; padding: 14px 24px; font-size: 12px; color: var(--muted); }
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
