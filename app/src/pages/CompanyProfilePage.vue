<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import {
  COMPANY_PROFILE_SELECT,
  brandOf,
  friendlyCompanyError,
  type CompanyProfileRow,
} from '@/lib/companyForm'
import CompanyTile from '@/components/CompanyTile.vue'
import CompanyStructurePanel from '@/components/CompanyStructurePanel.vue'
import CompanyPayrollPanel from '@/components/CompanyPayrollPanel.vue'
import PayrollPeriodsPanel from '@/components/PayrollPeriodsPanel.vue'
import WorkflowOwnersPanel from '@/components/WorkflowOwnersPanel.vue'
import DocumentsCard from '@/components/DocumentsCard.vue'
import PoliciesPanel from '@/components/PoliciesPanel.vue'
import EquipmentPanel from '@/components/EquipmentPanel.vue'
import LeaveCalendarPanel from '@/components/leave/LeaveCalendarPanel.vue'
import NotificationSettingsPanel from '@/components/NotificationSettingsPanel.vue'
import ChecklistTemplatePanel from '@/components/checklists/ChecklistTemplatePanel.vue'
import HandoverSettingsPanel from '@/components/handover/HandoverSettingsPanel.vue'
import StarterKitPanel from '@/components/equipment/StarterKitPanel.vue'
import FirstDayPanel from '@/components/welcome/FirstDayPanel.vue'
import ActivityPanel from '@/components/ActivityPanel.vue'
import InviteAccessDialog from '@/components/InviteAccessDialog.vue'
import TransferDialog, { type TransferTarget } from '@/components/TransferDialog.vue'
import { upcoming } from '@/lib/companyOps'
import { todayDb } from '@/lib/compensation'

/**
 * One company, tabbed (plan 014): Overview / People / Access / Hiring /
 * Projects / Integrations. The active tab is driven by ?tab= so every panel
 * is deep-linkable. All tab data loads in one Promise.all on mount — the
 * datasets are small and this avoids a query per tab switch.
 *
 * Platform admins edit the company's details and archive it from Overview.
 * Archiving is the only "delete": the row stays (23 tables reference it) but
 * leaves every list and picker. An archived company still opens by URL so old
 * links and history never 404.
 */

type TabId =
  | 'overview'
  | 'people'
  | 'structure'
  | 'access'
  | 'hiring'
  | 'documents'
  | 'equipment'
  | 'payroll'
  | 'leave'
  | 'projects'
  | 'integrations'
  | 'activity'
  | 'settings'

const TABS: { id: TabId; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'people', label: 'People' },
  { id: 'structure', label: 'Structure' },
  { id: 'access', label: 'Access' },
  { id: 'hiring', label: 'Hiring' },
  { id: 'documents', label: 'Documents' },
  { id: 'equipment', label: 'Equipment' },
  { id: 'payroll', label: 'Payroll' },
  { id: 'leave', label: 'Leave' },
  { id: 'projects', label: 'Projects' },
  { id: 'integrations', label: 'Integrations' },
  { id: 'activity', label: 'Activity' },
  { id: 'settings', label: 'Settings' },
]

type PersonRef = { id: string; full_name: string } | null
type CompanyRow = CompanyProfileRow & { director: PersonRef; hr_contact: PersonRef }

type EmploymentRow = {
  id: string
  job_title: string
  status: string
  start_date: string
  end_date: string | null
  last_working_date: string | null
  employment_type_key: string | null
  transferred_to_period_id: string | null
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

const auth = useAuthStore()
const dialogs = useDialogStore()
const archiving = ref(false)
const archiveError = ref<string | null>(null)

const isArchived = computed(() => company.value?.archived_at !== null)
// The holding is the root: it can be edited but never archived.
const canManage = computed(() => auth.isAdmin && company.value !== null && !isArchived.value)
const canArchive = computed(() => canManage.value && company.value?.kind === 'company')

const brand = computed(() => (company.value ? brandOf(company.value) : {}))

const addressLines = computed(() => {
  const c = company.value
  if (!c) return []
  const cityLine = [c.postcode, c.city].filter(Boolean).join(' ')
  return [c.address_line1, c.address_line2, cityLine, c.country].filter(
    (line): line is string => Boolean(line),
  )
})

function websiteLabel(url: string): string {
  return url.replace(/^https?:\/\//i, '').replace(/\/$/, '')
}

// The director/HR embeds go through people RLS: a configured person the
// viewer may not see comes back null, which is not the same as "not set".
function personFallback(personId: string | null): string {
  return personId ? 'Not visible with your access' : 'Not set'
}

async function archiveCompany(): Promise<void> {
  if (!company.value || !canArchive.value) return
  const ok = await dialogs.confirmAction({
    title: `Archive ${company.value.name}?`,
    hint: 'It leaves every list and picker; its people, access and history are kept.',
    confirmLabel: 'Archive company',
    danger: true,
  })
  if (!ok) return

  archiving.value = true
  archiveError.value = null
  // archive_company (migration 0026) refuses while anyone is still employed
  // here; the people are listed below with Transfer so the way out is clear.
  const { error: err } = await supabase.rpc('archive_company', { p_company_id: companyId })
  archiving.value = false

  if (err) {
    archiveError.value = friendlyCompanyError(err.message)
    archiveBlocked.value = /still employed here/.test(err.message)
    console.error('Company archive failed:', err.message)
    return
  }
  router.push({ name: 'companies' })
}

const archiveBlocked = ref(false)
const stillEmployed = computed(() => employments.value.filter((e) => e.status !== 'former'))
const transferDialog = ref<InstanceType<typeof TransferDialog> | null>(null)

function onTransferred(result: { applied: boolean; effectiveDate: string; companyName: string }): void {
  archiveError.value = null
  archiveBlocked.value = false
  error.value = null
  void load()
  notice.value = result.applied
    ? `Transferred to ${result.companyName}.`
    : `Transfer to ${result.companyName} scheduled for ${result.effectiveDate}.`
}
const notice = ref<string | null>(null)

// Payroll is only offered to payroll.summary holders (the function refuses
// everyone else anyway); Settings writes are admin-only by RLS.
const visibleTabs = computed(() =>
  TABS.filter((t) => {
    if (t.id === 'payroll') return auth.can(companyId, 'payroll.summary')
    // Settings: admins, and HR who may shape the checklists (the other panels guard their own writes).
    if (t.id === 'settings') return auth.isAdmin || auth.can(companyId, 'tasks.assign') || auth.can(companyId, 'it.assign')
    if (t.id === 'equipment') return auth.can(companyId, 'it.view')
    if (t.id === 'activity') {
      return ['access.manage', 'jobs.view', 'candidates.view'].some((cap) => auth.can(companyId, cap))
    }
    return true
  }),
)
const inviteDialog = ref<InstanceType<typeof InviteAccessDialog> | null>(null)
const upcomingPeople = computed(() => upcoming(employments.value, todayDb()))
// A stable array: a fresh literal on every render would make the card reload.
const documentScope = computed(() => (company.value ? [{ id: companyId, name: company.value.name }] : []))

const activeTab = computed<TabId>(() => {
  const raw = route.query.tab
  const id = Array.isArray(raw) ? raw[0] : raw
  return visibleTabs.value.some((t) => t.id === id) ? (id as TabId) : 'overview'
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

/** The People tab and the archive list open the same transfer dialog. */
function asTransferTarget(emp: EmploymentRow): TransferTarget {
  return {
    id: emp.id,
    company_id: companyId,
    person_id: emp.person?.id ?? '',
    job_title: emp.job_title,
    employment_type_key: emp.employment_type_key,
    start_date: emp.start_date,
    end_date: emp.end_date,
    company: company.value ? { name: company.value.name } : null,
  }
}

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
      .select(
        `${COMPANY_PROFILE_SELECT},
         director:people!companies_director_person_id_fkey(id, full_name),
         hr_contact:people!companies_hr_contact_person_id_fkey(id, full_name)`,
      )
      .eq('id', companyId)
      .maybeSingle(),
    supabase
      .from('employment_periods')
      .select(
        `id, job_title, status, start_date, end_date, last_working_date, employment_type_key, transferred_to_period_id,
         person:people!employment_periods_person_id_fkey(id, full_name, work_email)`,
      )
      .eq('company_id', companyId)
      .neq('status', 'former'),
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
  company.value = companyRes.data as CompanyRow

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
        <div class="company-banner" :style="{ '--accent': brand.accent_color ?? '' }">
          <CompanyTile :short-code="company.short_code" :brand="brand" size="large" />
          <div>
            <div class="eyebrow">Holding / company profile</div>
            <h1>
              {{ company.name }}
              <span v-if="isArchived" class="badge archived-badge">Archived</span>
            </h1>
            <p v-if="brand.tagline" class="tagline">{{ brand.tagline }}</p>
            <p class="meta">
              Part of Hut4 · {{ headcount }} people
              <template v-if="company.website">
                · <a :href="company.website" target="_blank" rel="noopener">{{ websiteLabel(company.website) }}</a>
              </template>
            </p>
          </div>
        </div>

        <p v-if="error" class="error-note" role="alert">{{ error }}</p>
        <p v-if="notice" class="notice" role="status">{{ notice }}</p>

        <div class="tabs" role="tablist" aria-label="Company profile">
          <button
            v-for="tab in visibleTabs"
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
            <div class="card-head">
              <div>
                <h2>Upcoming</h2>
                <p>Who is about to start or leave.</p>
              </div>
            </div>
            <div
              v-if="!upcomingPeople.starters.length && !upcomingPeople.departures.length"
              class="empty"
            >
              No starters or departures scheduled.
            </div>
            <template v-else>
              <div v-for="e in upcomingPeople.starters" :key="e.id" class="row upcoming-row">
                <div class="row-text">
                  <strong>{{ e.person?.full_name ?? '—' }}</strong>
                  <small>{{ e.job_title }} · {{ e.start_date < todayDb() ? 'was due to start' : 'starts' }} {{ e.start_date }}</small>
                </div>
                <span class="badge green">starting</span>
                <router-link v-if="e.person" class="button secondary small-btn" :to="{ name: 'person', params: { personId: e.person.id } }">
                  Open
                </router-link>
              </div>
              <div v-for="e in upcomingPeople.departures" :key="e.id" class="row upcoming-row">
                <div class="row-text">
                  <strong>{{ e.person?.full_name ?? '—' }}</strong>
                  <small>
                    {{ e.job_title }} · leaves {{ e.end_date }}
                    <template v-if="e.last_working_date"> · last day {{ e.last_working_date }}</template>
                  </small>
                </div>
                <span class="badge amber">departing</span>
                <router-link v-if="e.person" class="button secondary small-btn" :to="{ name: 'person', params: { personId: e.person.id } }">
                  Open
                </router-link>
              </div>
            </template>
          </div>

          <div class="card">
            <div class="card-head">
              <h2>Company details</h2>
              <router-link
                v-if="canManage"
                class="button secondary small-btn"
                :to="{ name: 'company-edit', params: { companyId } }"
              >
                Edit details
              </router-link>
            </div>

            <div class="detail-section">
              <h3>Registration</h3>
              <dl class="detail-grid">
                <div>
                  <dt>Legal name</dt>
                  <dd>{{ company.legal_name ?? company.name }}</dd>
                </div>
                <div>
                  <dt>Short code</dt>
                  <dd>{{ company.short_code }}</dd>
                </div>
                <div>
                  <dt>Registration number</dt>
                  <dd>{{ company.registration_number ?? '—' }}</dd>
                </div>
                <div>
                  <dt>VAT / tax ID</dt>
                  <dd>{{ company.tax_id ?? '—' }}</dd>
                </div>
                <div>
                  <dt>Registered address</dt>
                  <dd v-if="addressLines.length" class="address">
                    <span v-for="line in addressLines" :key="line">{{ line }}</span>
                  </dd>
                  <dd v-else>—</dd>
                </div>
                <div>
                  <dt>Parent organization</dt>
                  <dd>{{ company.parent_company_id ? 'Hut4' : '—' }}</dd>
                </div>
              </dl>
            </div>

            <div class="detail-section">
              <h3>Contacts</h3>
              <dl class="detail-grid">
                <div>
                  <dt>Director</dt>
                  <dd>
                    <router-link
                      v-if="company.director"
                      class="person-link"
                      :to="{ name: 'person', params: { personId: company.director.id } }"
                    >
                      {{ company.director.full_name }}
                    </router-link>
                    <template v-else>{{ personFallback(company.director_person_id) }}</template>
                  </dd>
                </div>
                <div>
                  <dt>HR contact</dt>
                  <dd>
                    <router-link
                      v-if="company.hr_contact"
                      class="person-link"
                      :to="{ name: 'person', params: { personId: company.hr_contact.id } }"
                    >
                      {{ company.hr_contact.full_name }}
                    </router-link>
                    <template v-else>{{ personFallback(company.hr_contact_person_id) }}</template>
                  </dd>
                </div>
                <div>
                  <dt>Email</dt>
                  <dd>
                    <a v-if="company.contact_email" :href="`mailto:${company.contact_email}`">{{ company.contact_email }}</a>
                    <template v-else>—</template>
                  </dd>
                </div>
                <div>
                  <dt>Phone</dt>
                  <dd>{{ company.contact_phone ?? '—' }}</dd>
                </div>
                <div>
                  <dt>Website</dt>
                  <dd>
                    <a v-if="company.website" :href="company.website" target="_blank" rel="noopener">
                      {{ websiteLabel(company.website) }}
                    </a>
                    <template v-else>—</template>
                  </dd>
                </div>
                <div>
                  <dt>HR workspace</dt>
                  <dd>Shared across the holding · one employing company per person</dd>
                </div>
              </dl>
            </div>
          </div>

          <div v-if="canArchive" class="card archive-card">
            <div class="row">
              <div class="row-text">
                <strong>Archive this company</strong>
                <small>
                  Removes it from every list and picker. People, access grants and history are kept
                  and this page stays reachable by link.
                </small>
              </div>
              <button
                class="button secondary small-btn danger"
                type="button"
                :disabled="archiving"
                @click="archiveCompany"
              >
                {{ archiving ? 'Archiving…' : 'Archive this company' }}
              </button>
            </div>
            <p v-if="archiveError" class="error-note archive-error" role="alert">{{ archiveError }}</p>
            <div v-if="archiveBlocked && stillEmployed.length" class="still-employed">
              <div v-for="emp in stillEmployed" :key="emp.id" class="row">
                <div class="row-text">
                  <strong>{{ emp.person?.full_name ?? '—' }}</strong>
                  <small>{{ emp.job_title }} · {{ emp.status.replace('_', ' ') }}</small>
                </div>
                <button
                  v-if="auth.can(companyId, 'employment.edit') && !emp.transferred_to_period_id"
                  class="button secondary small-btn"
                  type="button"
                  @click="transferDialog?.open(asTransferTarget(emp), emp.person?.full_name ?? '')"
                >
                  Transfer
                </button>
              </div>
            </div>
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
                  <th></th>
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
                  <td>
                    <button
                      v-if="auth.can(companyId, 'employment.edit') && emp.status !== 'former' && !emp.transferred_to_period_id"
                      class="button secondary small-btn"
                      type="button"
                      @click="transferDialog?.open(asTransferTarget(emp), emp.person?.full_name ?? '')"
                    >
                      Transfer
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <CompanyStructurePanel v-else-if="activeTab === 'structure'" :company-id="companyId" />

        <div v-else-if="activeTab === 'access'" class="card">
          <div class="card-head">
            <div>
              <h2>Access</h2>
              <p>Invite creates the account; capabilities are granted in the access editor afterwards.</p>
            </div>
            <button v-if="canManage" class="button small-btn" type="button" @click="inviteDialog?.openInvite()">
              Invite person
            </button>
          </div>
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

        <div v-else-if="activeTab === 'documents'" class="stack">
          <DocumentsCard :companies="documentScope" title="Company documents" />
          <PoliciesPanel :company-id="company.kind === 'holding' ? null : companyId" />
        </div>

        <EquipmentPanel v-else-if="activeTab === 'equipment'" :company-id="companyId" />

        <div v-else-if="activeTab === 'payroll'" class="stack">
          <CompanyPayrollPanel :company-id="companyId" />
          <PayrollPeriodsPanel :company-id="companyId" :company-code="company.short_code" />
        </div>

        <div v-else-if="activeTab === 'leave'" class="stack">
          <LeaveCalendarPanel :companies="[{ id: companyId, name: company.name, country_code: company.country_code }]" />
          <p class="tab-foot">
            Requests, balances and holiday calendars live under
            <router-link :to="{ name: 'leave', query: { company: companyId } }">Leave</router-link>.
            <span v-if="!company.country_code">This company has no country code yet — set it in Edit so holidays apply and leave can be requested.</span>
          </p>
        </div>

        <ActivityPanel v-else-if="activeTab === 'activity'" :company-id="companyId" />

        <div v-else-if="activeTab === 'settings'" class="stack">
          <ChecklistTemplatePanel :company-id="companyId" :company-name="company.name" />
          <HandoverSettingsPanel :company-id="companyId" :company-name="company.name" />
          <StarterKitPanel :company-id="companyId" :company-name="company.name" />
          <FirstDayPanel :company-id="companyId" :company-name="company.name" />
          <template v-if="auth.isAdmin">
            <WorkflowOwnersPanel :company-id="companyId" />
            <NotificationSettingsPanel :company-id="companyId" />
          </template>
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
      <InviteAccessDialog ref="inviteDialog" @invited="load" />
      <TransferDialog ref="transferDialog" @transferred="onTransferred" />
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
.company-banner h1 { margin: 4px 0 5px; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.company-banner .meta { margin: 0; font-size: 12px; color: var(--muted); }
.archived-badge { font-size: 11px; letter-spacing: 0.04em; text-transform: uppercase; }
.archive-card { margin-top: 18px; }
.archive-card .row { border-top: 0; }
.archive-card .row-text small { line-height: 1.6; }
.archive-error { margin: 0 24px 18px; }
.danger { color: var(--red); border-color: #e8d3d3; }
.danger:hover { background: #f9eeee; }
.company-banner .tagline { margin: 0 0 5px; font-size: 13px; color: var(--ink); opacity: 0.85; }
.company-banner .meta a { color: var(--green); text-decoration: none; }
.company-banner .meta a:hover { text-decoration: underline; }
.detail-section { border-top: 1px solid var(--line); }
.detail-section:first-of-type { border-top: 0; }
.detail-section h3 {
  margin: 0;
  padding: 18px 24px 0;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--muted);
}
.detail-grid .address span { display: block; }
.detail-grid dd a { color: var(--green); text-decoration: none; }
.detail-grid dd a:hover { text-decoration: underline; }
.stack { display: grid; gap: 22px; }
.tab-foot { font-size: 12px; color: var(--muted); margin: 0; }
.notice { padding: 12px 15px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin-bottom: 16px; }
.still-employed { border-top: 1px solid #edf0eb; margin-top: 12px; }
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
.detail-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 18px 20px; padding: 16px 24px 23px; margin: 0; }
.detail-grid dt { font-size: 11px; color: var(--muted); margin-bottom: 6px; }
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
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
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
