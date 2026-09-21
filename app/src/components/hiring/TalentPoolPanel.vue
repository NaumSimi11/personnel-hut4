<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import CompanyFilter from '@/components/CompanyFilter.vue'
import AddCandidateDialog from '@/components/AddCandidateDialog.vue'
import SourceToJobDialog from '@/components/SourceToJobDialog.vue'
import {
  EMPTY_POOL_FILTERS,
  SOURCE_FALLBACK_LABEL,
  contactBadge,
  contactState,
  poolFiltersFromQuery,
  poolPayload,
  poolQuery,
  type PoolFilters,
  type PoolRow,
} from '@/lib/candidatePool'
import { shortDate } from '@/lib/leave'
import { todayDb } from '@/lib/compensation'
import type { Json } from '@/types/database'

/**
 * The talent pool tab (plan 052): everyone recruitment has found, added or
 * imported, across the holding, for pool holders. search_candidates does
 * the searching and the paging; the filters live on the address bar so a
 * search survives opening a record. Every gate here is a hint — the RPC
 * and the policies decide.
 */

const SEARCH_DEBOUNCE_MS = 300
const SKILLS_SHOWN = 4

type SourceOption = { key: string; label: string }
type SearchResult = { total: number; rows: PoolRow[] }

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const filters = ref<PoolFilters>(poolFiltersFromQuery(route.query))
const searchText = ref(filters.value.q)
const rows = ref<PoolRow[]>([])
const total = ref(0)
const loading = ref(true)
const loadingMore = ref(false)
const error = ref<string | null>(null)
const companies = ref<{ id: string; name: string }[]>([])
const sources = ref<SourceOption[]>([])
const addDialog = ref<InstanceType<typeof AddCandidateDialog> | null>(null)
const sourceDialog = ref<InstanceType<typeof SourceToJobDialog> | null>(null)
const sourceTarget = ref<PoolRow | null>(null)

const today = todayDb()
const filtersActive = computed(() => Object.keys(poolQuery(filters.value)).length > 0)
const hasMore = computed(() => rows.value.length < total.value)
const countLine = computed(
  () => `${total.value.toLocaleString('en-GB')} ${total.value === 1 ? 'person' : 'people'} · showing ${rows.value.length.toLocaleString('en-GB')}`,
)

let currentPage = 0
let requestSeq = 0
let searchTimer: ReturnType<typeof setTimeout> | undefined

function setFilters(patch: Partial<PoolFilters>): void {
  const next = { ...filters.value, ...patch }
  if ((Object.keys(next) as (keyof PoolFilters)[]).every((k) => next[k] === filters.value[k])) return
  filters.value = next
}

function clearFilters(): void {
  searchText.value = ''
  filters.value = { ...EMPTY_POOL_FILTERS }
}

async function load(page: number): Promise<void> {
  const seq = ++requestSeq
  if (page === 0) loading.value = true
  else loadingMore.value = true
  error.value = null
  const { data, error: err } = await supabase.rpc('search_candidates', { p: poolPayload(filters.value, page) as Json })
  if (seq !== requestSeq) return
  loading.value = false
  loadingMore.value = false
  if (err) {
    error.value = 'Could not load the talent pool.'
    console.error('Talent pool search failed:', err.message)
    return
  }
  const result = data as SearchResult
  rows.value = page === 0 ? result.rows : [...rows.value, ...result.rows]
  total.value = result.total
  currentPage = page
}

async function loadLookups(): Promise<void> {
  const [companiesRes, sourcesRes] = await Promise.all([
    supabase.from('companies').select('id, name').is('archived_at', null).order('name'),
    supabase.from('candidate_sources').select('key, label').is('archived_at', null).order('sort_order'),
  ])
  if (companiesRes.error) console.error('Companies load failed:', companiesRes.error.message)
  if (sourcesRes.error) console.error('Candidate sources load failed:', sourcesRes.error.message)
  companies.value = (companiesRes.data ?? []).filter((c) => auth.can(c.id, 'candidates.view'))
  sources.value = sourcesRes.data ?? []
}

// ------------------------------------------------------------ the cells

function titleLine(r: PoolRow): string {
  return [r.current_title, r.current_employer].filter(Boolean).join(' @ ') || '—'
}

function skillsLine(r: PoolRow): string {
  if (!r.skills.length) return '—'
  const rest = r.skills.length - SKILLS_SHOWN
  return r.skills.slice(0, SKILLS_SHOWN).join(', ') + (rest > 0 ? ` +${rest}` : '')
}

/** From the visible list only — "—" when none, never a zero. */
function applicationsLine(r: PoolRow): string {
  const latest = r.applications[0]
  if (!latest) return '—'
  return `${r.applications.length} · latest: ${latest.job_title}, ${latest.company_name} — ${latest.stage_key}`
}

function activityDate(r: PoolRow): string {
  return shortDate(r.last_activity_at.slice(0, 10))
}

function ruleBadge(r: PoolRow): { label: string; tone: string } {
  return { label: contactBadge(r, today), tone: contactState(r, today) === 'do_not_contact' ? 'amber' : 'blue' }
}

/** Why "Add to job" is off — the sentences the RPC would answer with. */
function blockedReason(r: PoolRow): string | null {
  if (r.archived_at) return `${r.full_name} is archived. Restore the pool record first.`
  if (r.do_not_contact) return `${r.full_name} asked not to be contacted again.`
  return null
}

// ---------------------------------------------------------- the actions

async function addToJob(r: PoolRow): Promise<void> {
  sourceTarget.value = r
  await nextTick()
  void sourceDialog.value?.open()
}

function loadMore(): void {
  void load(currentPage + 1)
}

function onCreated(id: string): void {
  void router.push({ name: 'candidate', params: { candidateId: id } })
}

watch(searchText, (q) => {
  clearTimeout(searchTimer)
  searchTimer = setTimeout(() => setFilters({ q }), SEARCH_DEBOUNCE_MS)
})

watch(filters, (next) => {
  void router.replace({ query: { tab: 'pool', ...poolQuery(next) } })
  void load(0)
})

onMounted(() => {
  void loadLookups()
  void load(0)
})
onBeforeUnmount(() => clearTimeout(searchTimer))
</script>

<template>
  <div class="card" data-testid="talent-pool">
    <div class="card-head">
      <div>
        <h2>Talent pool</h2>
        <p>Everyone recruitment has found, added or imported — across the holding. Attach a person to a job instead of typing them again.</p>
      </div>
      <button class="button" type="button" data-testid="pool-add" @click="addDialog?.open()">Add to pool</button>
    </div>

    <div class="filters">
      <input
        v-model="searchText"
        class="search"
        type="search"
        placeholder="Name, email, phone, LinkedIn, title, skill"
        aria-label="Search the talent pool"
        data-testid="pool-search"
      />
      <CompanyFilter
        id="pool-company"
        :model-value="filters.companyId"
        :companies="companies"
        all-label="Applied anywhere"
        label="Applied to"
        @update:model-value="(id) => setFilters({ companyId: id })"
      />
      <label class="filter">
        <span class="filter-label">Source</span>
        <select :value="filters.sourceKey" aria-label="Source" @change="setFilters({ sourceKey: ($event.target as HTMLSelectElement).value })">
          <option value="">Any source</option>
          <option v-for="s in sources" :key="s.key" :value="s.key">{{ s.label }}</option>
        </select>
      </label>
      <label class="filter">
        <span class="filter-label">Contact</span>
        <select :value="filters.contact" aria-label="Contact rule" @change="setFilters({ contact: ($event.target as HTMLSelectElement).value as PoolFilters['contact'] })">
          <option value="any">Anyone</option>
          <option value="ok">Can be contacted</option>
          <option value="do_not_contact">Do not contact</option>
          <option value="wait">Contact later</option>
        </select>
      </label>
      <label class="filter">
        <span class="filter-label">Activity</span>
        <select :value="filters.activity" aria-label="Last activity" @change="setFilters({ activity: ($event.target as HTMLSelectElement).value as PoolFilters['activity'] })">
          <option value="any">Any time</option>
          <option value="90d">Last 90 days</option>
          <option value="1y">Last year</option>
          <option value="older">Older than a year</option>
        </select>
      </label>
      <label class="check">
        <input type="checkbox" :checked="filters.showArchived" @change="setFilters({ showArchived: ($event.target as HTMLInputElement).checked })" />
        Show archived
      </label>
    </div>

    <div v-if="error" class="empty">
      <p>{{ error }}</p>
      <button class="button secondary small-btn" type="button" @click="load(0)">Retry</button>
    </div>
    <div v-else-if="loading" class="empty">Loading the talent pool…</div>
    <div v-else-if="!rows.length && !filtersActive" class="empty">The talent pool is empty. Add a candidate or import an export.</div>
    <div v-else-if="!rows.length" class="empty">
      <p>No candidates match.</p>
      <button class="button secondary small-btn" type="button" @click="clearFilters">Clear filters</button>
    </div>
    <template v-else>
      <p class="count" data-testid="pool-count">{{ countLine }}</p>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Person</th>
              <th>Title</th>
              <th>Skills</th>
              <th>Source</th>
              <th>Applications</th>
              <th>Last activity</th>
              <th>Rule</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in rows" :key="r.id" :data-testid="`pool-row-${r.id}`">
              <td>
                <b><router-link class="name" :to="{ name: 'candidate', params: { candidateId: r.id } }">{{ r.full_name }}</router-link></b>
                <small v-if="r.email || r.phone" class="sub">{{ [r.email, r.phone].filter(Boolean).join(' · ') }}</small>
              </td>
              <td>{{ titleLine(r) }}</td>
              <td>{{ skillsLine(r) }}</td>
              <td><span class="badge">{{ r.source_label ?? SOURCE_FALLBACK_LABEL }}</span></td>
              <td>{{ applicationsLine(r) }}</td>
              <td>{{ activityDate(r) }}</td>
              <td>
                <div class="badges">
                  <span v-if="ruleBadge(r).label" class="badge" :class="ruleBadge(r).tone">{{ ruleBadge(r).label }}</span>
                  <span v-if="r.archived_at" class="badge">Archived</span>
                </div>
              </td>
              <td class="actions">
                <div class="action-group">
                  <router-link class="button secondary small-btn" :to="{ name: 'candidate', params: { candidateId: r.id } }">Open</router-link>
                  <button
                    class="button secondary small-btn"
                    type="button"
                    :disabled="Boolean(blockedReason(r))"
                    :title="blockedReason(r) ?? undefined"
                    :data-testid="`pool-add-to-job-${r.id}`"
                    @click="addToJob(r)"
                  >
                    Add to job
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div v-if="hasMore" class="more">
        <button class="button secondary small-btn" type="button" :disabled="loadingMore" data-testid="pool-more" @click="loadMore">
          {{ loadingMore ? 'Loading…' : 'Show more' }}
        </button>
      </div>
    </template>

    <AddCandidateDialog ref="addDialog" @created="onCreated" />
    <SourceToJobDialog
      v-if="sourceTarget"
      ref="sourceDialog"
      :candidate-id="sourceTarget.id"
      :candidate-name="sourceTarget.full_name"
      :contact-again-after="sourceTarget.contact_later ? sourceTarget.contact_again_after : null"
    />
  </div>
</template>

<style scoped>
.filters { display: flex; gap: 10px; flex-wrap: wrap; align-items: end; padding: 14px 24px; border-bottom: 1px solid var(--line); background: #fafbf9; }
.filter { display: inline-grid; gap: 7px; }
.filter-label { font-size: 11px; font-weight: 550; color: #566653; }
.search, .filter select { border: 1px solid var(--line); background: #fff; padding: 8px 10px; font-size: 12px; color: var(--ink); min-width: 180px; }
.search { min-width: 240px; }
.check { display: inline-flex; gap: 7px; align-items: center; font-size: 12px; min-height: 34px; }
.count { margin: 0; padding: 10px 24px; font-size: 11px; color: var(--muted); }
.empty p { margin: 0 0 12px; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { text-align: left; font-size: 11px; font-weight: 550; color: var(--muted); padding: 10px 24px; border-bottom: 1px solid var(--line); }
td { padding: 12px 24px; border-bottom: 1px solid var(--line); vertical-align: middle; }
td b { font-weight: 600; }
.name { color: var(--ink); text-decoration: none; }
.name:hover { color: var(--green); text-decoration: underline; }
.sub { display: block; font-size: 11px; color: var(--muted); margin-top: 2px; }
.badges { display: flex; gap: 6px; flex-wrap: wrap; }
.actions { text-align: right; white-space: nowrap; }
.action-group { display: inline-flex; gap: 6px; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.more { display: flex; justify-content: center; padding: 14px 24px; }
</style>
