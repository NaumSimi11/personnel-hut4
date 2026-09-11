<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'

/**
 * One company, tabbed (plan 014): Overview / People / Access / Hiring /
 * Projects / Integrations. The active tab is driven by ?tab= so every panel
 * is deep-linkable. All tab data loads in one Promise.all on mount — the
 * datasets are small and this avoids a query per tab switch.
 */

type TabId = 'overview' | 'people' | 'access' | 'hiring' | 'projects' | 'integrations'

const TABS: { id: TabId; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'people', label: 'People' },
  { id: 'access', label: 'Access' },
  { id: 'hiring', label: 'Hiring' },
  { id: 'projects', label: 'Projects' },
  { id: 'integrations', label: 'Integrations' },
]

type CompanyRow = {
  id: string
  parent_company_id: string | null
  kind: string
  name: string
  short_code: string
}

type EmploymentRow = {
  id: string
  job_title: string
  status: string
  start_date: string
  person: { id: string; full_name: string; work_email: string | null } | null
}

type HiringRequestRow = { id: string; title: string; status: string }
type JobRow = { id: string; title: string; status: string }

type AccessGrantRow = {
  id: string
  person: { id: string; full_name: string } | null
  grant_capabilities: { capability_key: string }[]
}

type ProjectRow = {
  id: string
  name: string
  status: string | null
  provider_key: string
  last_synced_at: string
  external_project_members: { person: { full_name: string } | null }[]
}

type ProviderRow = { key: string; label: string; kind: string }
type IntegrationRow = { id: string; provider_key: string; status: string }

const route = useRoute()
const router = useRouter()
const companyId = route.params.companyId as string

const company = ref<CompanyRow | null>(null)
const employments = ref<EmploymentRow[]>([])
const hiringRequests = ref<HiringRequestRow[]>([])
const jobs = ref<JobRow[]>([])
const onboardingInProgressCount = ref(0)
const accessGrants = ref<AccessGrantRow[]>([])
const projects = ref<ProjectRow[]>([])
const providers = ref<ProviderRow[]>([])
const integrations = ref<IntegrationRow[]>([])

const loading = ref(true)
const notFound = ref(false)
const error = ref<string | null>(null)

const activeTab = computed<TabId>(() => {
  const raw = route.query.tab
  const id = Array.isArray(raw) ? raw[0] : raw
  return TABS.some((t) => t.id === id) ? (id as TabId) : 'overview'
})

function selectTab(id: TabId): void {
  router.replace({ query: { tab: id } })
}

const headcount = computed(() => employments.value.length)
const submittedHiringCount = computed(
  () => hiringRequests.value.filter((r) => r.status === 'submitted').length,
)
const connectedChannelsCount = computed(
  () => integrations.value.filter((i) => i.status === 'connected').length,
)

function initials(name: string): string {
  return name.split(' ').map((p) => p[0] ?? '').slice(0, 2).join('')
}

function hiringRequestBadgeClass(status: string): string {
  if (status === 'submitted') return 'amber'
  if (status === 'approved') return 'green'
  if (status === 'changes_requested') return 'blue'
  return ''
}

function jobBadgeClass(status: string): string {
  if (status === 'open') return 'green'
  if (status === 'filled') return 'blue'
  return ''
}

function integrationBadgeClass(status: string): string {
  if (status === 'connected') return 'green'
  if (status === 'sync_issue' || status === 'authorization_required') return 'amber'
  return ''
}

function integrationFor(providerKey: string): IntegrationRow | null {
  return integrations.value.find((i) => i.provider_key === providerKey) ?? null
}

function projectMemberNames(project: ProjectRow): string {
  return project.external_project_members
    .map((m) => m.person?.full_name)
    .filter((name): name is string => Boolean(name))
    .join(', ')
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  notFound.value = false

  const [
    companyRes,
    employmentsRes,
    hiringRequestsRes,
    jobsRes,
    onboardingCountRes,
    accessGrantsRes,
    projectsRes,
    providersRes,
    integrationsRes,
  ] = await Promise.all([
    supabase
      .from('companies')
      .select('id, parent_company_id, kind, name, short_code')
      .eq('id', companyId)
      .maybeSingle(),
    supabase
      .from('employment_periods')
      .select(
        `id, job_title, status, start_date,
         person:people!employment_periods_person_id_fkey(id, full_name, work_email)`,
      )
      .eq('company_id', companyId)
      .is('end_date', null),
    supabase.from('hiring_requests').select('id, title, status').eq('company_id', companyId),
    supabase.from('jobs').select('id, title, status').eq('company_id', companyId),
    supabase
      .from('plans')
      .select('*', { count: 'exact', head: true })
      .eq('company_id', companyId)
      .eq('kind', 'onboarding')
      .eq('status', 'in_progress'),
    supabase
      .from('access_grants')
      .select(
        `id, person:people!access_grants_person_id_fkey(id, full_name),
         grant_capabilities(capability_key)`,
      )
      .eq('company_id', companyId),
    supabase
      .from('external_projects')
      .select(
        `id, name, status, provider_key, last_synced_at,
         external_project_members!external_project_members_project_id_fkey(
           person:people!external_project_members_person_id_fkey(full_name)
         )`,
      )
      .eq('company_id', companyId),
    supabase.from('providers').select('key, label, kind').is('archived_at', null),
    supabase.from('integrations').select('id, provider_key, status').eq('company_id', companyId),
  ])

  if (companyRes.error || !companyRes.data) {
    notFound.value = true
    error.value = 'Company not found or not visible with your access.'
    loading.value = false
    return
  }
  company.value = companyRes.data

  let hadError = false
  const logIfError = (label: string, err: { message: string } | null) => {
    if (!err) return
    hadError = true
    console.error(`Company profile: ${label} failed:`, err.message)
  }

  logIfError('employments', employmentsRes.error)
  logIfError('hiring requests', hiringRequestsRes.error)
  logIfError('jobs', jobsRes.error)
  logIfError('onboarding count', onboardingCountRes.error)
  logIfError('access grants', accessGrantsRes.error)
  logIfError('projects', projectsRes.error)
  logIfError('providers', providersRes.error)
  logIfError('integrations', integrationsRes.error)

  employments.value = (employmentsRes.data ?? []) as EmploymentRow[]
  hiringRequests.value = (hiringRequestsRes.data ?? []) as HiringRequestRow[]
  jobs.value = (jobsRes.data ?? []) as JobRow[]
  onboardingInProgressCount.value = onboardingCountRes.count ?? 0
  accessGrants.value = (accessGrantsRes.data ?? []) as AccessGrantRow[]
  projects.value = (projectsRes.data ?? []) as ProjectRow[]
  providers.value = (providersRes.data ?? []) as ProviderRow[]
  integrations.value = (integrationsRes.data ?? []) as IntegrationRow[]

  error.value = hadError ? 'Could not load this company.' : null
  loading.value = false
}

onMounted(load)
</script>

<template>
  <div>
    <p v-if="notFound" class="error-note" role="alert">{{ error }}</p>

    <template v-else>
      <router-link class="back-link" :to="{ name: 'companies' }">← Companies</router-link>

      <div v-if="loading" class="empty">Loading company…</div>
      <template v-else-if="company">
        <div class="company-banner">
          <span class="short-tile" aria-hidden="true">{{ company.short_code }}</span>
          <div>
            <div class="eyebrow">Holding / company profile</div>
            <h1>{{ company.name }}</h1>
            <p class="meta">Part of Hut4 · {{ headcount }} people</p>
          </div>
        </div>

        <p v-if="error" class="error-note" role="alert">{{ error }}</p>

        <div class="tabs" role="tablist" aria-label="Company profile">
          <button
            v-for="tab in TABS"
            :key="tab.id"
            class="tab"
            :class="{ active: activeTab === tab.id }"
            type="button"
            role="tab"
            :aria-selected="activeTab === tab.id"
            @click="selectTab(tab.id)"
          >
            {{ tab.label }}
          </button>
        </div>

        <div v-if="activeTab === 'overview'">
          <div class="metrics">
            <div class="card metric-tile">
              <span class="metric-label">People</span>
              <span class="metric-value">{{ headcount }}</span>
            </div>
            <div class="card metric-tile">
              <span class="metric-label">Hiring requests</span>
              <span class="metric-value">{{ submittedHiringCount }}</span>
            </div>
            <div class="card metric-tile">
              <span class="metric-label">Onboarding</span>
              <span class="metric-value">{{ onboardingInProgressCount }}</span>
            </div>
            <div class="card metric-tile">
              <span class="metric-label">Connected channels</span>
              <span class="metric-value">{{ connectedChannelsCount }}</span>
            </div>
          </div>

          <div class="card">
            <div class="card-head"><h2>Company details</h2></div>
            <dl class="detail-grid">
              <div>
                <dt>Parent organization</dt>
                <dd>{{ company.parent_company_id ? 'Hut4' : '—' }}</dd>
              </div>
              <div>
                <dt>Short code</dt>
                <dd>{{ company.short_code }}</dd>
              </div>
              <div>
                <dt>Employment structure</dt>
                <dd>One employing company per person</dd>
              </div>
              <div>
                <dt>HR workspace</dt>
                <dd>Shared across the holding</dd>
              </div>
            </dl>
          </div>
        </div>

        <div v-else-if="activeTab === 'people'" class="card">
          <div class="card-head"><h2>People</h2></div>
          <div v-if="!employments.length" class="empty">Nobody is employed here yet.</div>
          <div v-else class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Person</th>
                  <th>Role</th>
                  <th>Status</th>
                  <th>Start date</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="emp in employments" :key="emp.id">
                  <td>
                    <router-link
                      v-if="emp.person"
                      class="person-cell person-link"
                      :to="{ name: 'person', params: { personId: emp.person.id } }"
                    >
                      <span class="avatar" aria-hidden="true">{{ initials(emp.person.full_name) }}</span>
                      <div>
                        <strong>{{ emp.person.full_name }}</strong>
                        <small>{{ emp.person.work_email ?? '—' }}</small>
                      </div>
                    </router-link>
                    <span v-else>—</span>
                  </td>
                  <td>{{ emp.job_title }}</td>
                  <td>
                    <span class="badge" :class="emp.status === 'active' ? 'green' : 'blue'">
                      {{ emp.status.replace('_', ' ') }}
                    </span>
                  </td>
                  <td>{{ emp.start_date }}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div v-else-if="activeTab === 'access'" class="card">
          <div class="card-head"><h2>Access</h2></div>
          <div v-if="!accessGrants.length" class="empty">No grants in this company yet.</div>
          <div v-else>
            <div v-for="g in accessGrants" :key="g.id" class="row">
              <div class="row-text">
                <strong>{{ g.person?.full_name ?? '—' }}</strong>
                <small>{{ g.grant_capabilities.length }} capabilities</small>
              </div>
              <router-link
                v-if="g.person"
                class="button secondary small-btn"
                :to="{ name: 'access-editor', params: { personId: g.person.id }, query: { company: companyId } }"
              >
                Edit
              </router-link>
            </div>
          </div>
        </div>

        <div v-else-if="activeTab === 'hiring'">
          <div class="card">
            <div class="card-head"><h2>Hiring requests</h2></div>
            <div v-if="!hiringRequests.length" class="empty">
              No hiring requests for this company yet.
            </div>
            <div v-else>
              <div v-for="r in hiringRequests" :key="r.id" class="row">
                <div class="row-text"><strong>{{ r.title }}</strong></div>
                <span class="badge" :class="hiringRequestBadgeClass(r.status)">
                  {{ r.status.replace('_', ' ') }}
                </span>
              </div>
            </div>
          </div>

          <div class="card">
            <div class="card-head"><h2>Jobs</h2></div>
            <div v-if="!jobs.length" class="empty">No jobs opened for this company yet.</div>
            <div v-else>
              <div v-for="j in jobs" :key="j.id" class="row">
                <div class="row-text"><strong>{{ j.title }}</strong></div>
                <span class="badge" :class="jobBadgeClass(j.status)">{{ j.status.replace('_', ' ') }}</span>
                <router-link class="button secondary small-btn" :to="{ name: 'job', params: { jobId: j.id } }">
                  Open job
                </router-link>
              </div>
            </div>
          </div>
        </div>

        <div v-else-if="activeTab === 'projects'" class="card">
          <div class="card-head"><h2>Projects</h2></div>
          <div v-if="!projects.length" class="empty">No projects synced for this company.</div>
          <div v-else>
            <div v-for="pr in projects" :key="pr.id" class="row">
              <div class="row-text">
                <strong>{{ pr.name }}</strong>
                <small>
                  {{ pr.provider_key }} · last sync {{ new Date(pr.last_synced_at).toLocaleString() }}
                  <template v-if="projectMemberNames(pr)"> · {{ projectMemberNames(pr) }}</template>
                </small>
              </div>
              <span class="badge" :class="pr.status === 'Active' ? 'green' : ''">{{ pr.status ?? '—' }}</span>
            </div>
          </div>
          <p class="inline-note">Project facts stay in the external system. This panel is read-only.</p>
        </div>

        <div v-else-if="activeTab === 'integrations'" class="card">
          <div class="card-head"><h2>Integrations</h2></div>
          <div v-if="!providers.length" class="empty">No providers configured.</div>
          <div v-else>
            <div v-for="p in providers" :key="p.key" class="row">
              <div class="row-text">
                <strong>{{ p.label }}</strong>
                <small>{{ p.kind }}</small>
              </div>
              <span
                class="badge"
                :class="integrationFor(p.key) ? integrationBadgeClass(integrationFor(p.key)!.status) : ''"
              >
                {{ integrationFor(p.key)?.status.replace('_', ' ') ?? 'Not connected' }}
              </span>
            </div>
          </div>
          <p class="inline-note">
            No credentials are collected here; connections are configured per company and confirmed
            by the provider.
          </p>
        </div>
      </template>
    </template>
  </div>
</template>

<style scoped>
.back-link {
  display: inline-block;
  font-size: 11px;
  color: var(--muted);
  text-decoration: none;
  margin-bottom: 16px;
}
.back-link:hover { color: var(--green); }
.company-banner { display: flex; align-items: center; gap: 18px; margin-bottom: 20px; }
.company-banner h1 { margin: 4px 0 5px; }
.company-banner .meta { margin: 0; font-size: 12px; color: var(--muted); }
.short-tile {
  display: grid;
  place-items: center;
  width: 58px;
  height: 58px;
  background: var(--green-soft);
  color: var(--green);
  border-radius: 14px;
  font-size: 20px;
  font-weight: 650;
  flex-shrink: 0;
}
.tabs { display: flex; gap: 22px; border-bottom: 1px solid var(--line); margin-bottom: 22px; overflow: auto; }
.tab {
  border: 0;
  background: transparent;
  color: var(--muted);
  padding: 0 1px 13px;
  border-bottom: 2px solid transparent;
  border-radius: 0;
  white-space: nowrap;
  font-size: 12px;
}
.tab.active { color: var(--green); font-weight: 600; border-bottom-color: var(--green); }
.metrics { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; margin-bottom: 22px; }
@media (max-width: 900px) {
  .metrics { grid-template-columns: repeat(2, 1fr); }
}
.metric-tile { display: flex; flex-direction: column; gap: 8px; padding: 18px 20px; }
.metric-label { font-size: 11px; color: var(--muted); font-weight: 550; }
.metric-value { font-size: 26px; font-weight: 750; letter-spacing: -0.02em; }
.detail-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 18px 20px; padding: 23px 24px; margin: 0; }
.detail-grid dt { font-size: 10px; color: var(--muted); margin-bottom: 6px; }
.detail-grid dd { margin: 0; font-size: 12px; }
@media (max-width: 560px) {
  .detail-grid { grid-template-columns: 1fr; }
}
.row {
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
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.person-link { text-decoration: none; color: inherit; }
.person-link:hover strong { color: var(--green); text-decoration: underline; }
.inline-note {
  font-size: 11px;
  line-height: 1.65;
  padding: 14px 24px;
  color: var(--muted);
  border-top: 1px solid var(--line);
  margin: 0;
}
</style>
