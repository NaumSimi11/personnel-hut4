<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import PrivateDetailsCard from '@/components/PrivateDetailsCard.vue'
import ScheduleDepartureDialog from '@/components/ScheduleDepartureDialog.vue'
import ScheduleChangeDialog, { type ChangeTarget } from '@/components/ScheduleChangeDialog.vue'
import CompensationCard from '@/components/CompensationCard.vue'
import DocumentsCard from '@/components/DocumentsCard.vue'
import DocumentRequestsCard from '@/components/DocumentRequestsCard.vue'
import { describeChanges, type Lookups } from '@/lib/employmentChanges'
import { departureState, friendlyDepartureError } from '@/lib/departure'

type Employment = {
  id: string
  company_id: string
  job_title: string
  status: string
  start_date: string
  end_date: string | null
  last_working_date: string | null
  employment_type_key: string | null
  person_id: string
  department_id: string | null
  location_id: string | null
  manager_id: string | null
  company: { name: string } | null
  department: { name: string } | null
  location: { name: string } | null
  manager: { id: string; full_name: string } | null
  // The open offboarding plan, if a departure is scheduled (plan 016).
  plans: { id: string; kind: string; status: string }[]
  // Scheduled employment changes not yet applied (plan 022).
  employment_changes: { id: string; effective_date: string; changes: Record<string, unknown>; reason: string | null; status: string }[]
}
type Grant = {
  company_id: string
  company: { name: string } | null
  grant_capabilities: { capability_key: string }[]
}

const route = useRoute()
const auth = useAuthStore()
const personId = route.params.personId as string

const person = ref<{ full_name: string; work_email: string | null; user_id: string | null } | null>(null)
const employments = ref<Employment[]>([])
const grants = ref<Grant[]>([])
// Companies the person has (had) employment with — where their documents may live.
const personCompanies = computed(() => {
  const seen = new Map<string, { id: string; name: string }>()
  for (const e of employments.value) if (!seen.has(e.company_id)) seen.set(e.company_id, { id: e.company_id, name: e.company?.name ?? '' })
  return [...seen.values()]
})
const companies = ref<{ id: string; name: string }[]>([])
const employmentTypes = ref<{ key: string; label: string }[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const showAddEmployment = ref(false)
const empForm = ref({
  companyId: '',
  jobTitle: '',
  employmentType: 'full_time',
  startDate: new Date().toISOString().slice(0, 10),
})
const busy = ref(false)
const departureDialog = ref<InstanceType<typeof ScheduleDepartureDialog> | null>(null)
const changeDialog = ref<InstanceType<typeof ScheduleChangeDialog> | null>(null)
const lookups = ref<Lookups>({ departments: {}, locations: {}, people: {}, employmentTypes: {} })

function canEditEmployment(emp: Employment): boolean {
  return auth.can(emp.company_id, 'employment.edit')
}

function pendingChanges(emp: Employment) {
  return emp.employment_changes
    .filter((c) => c.status === 'scheduled')
    .sort((a, b) => a.effective_date.localeCompare(b.effective_date))
}

function employmentFacts(emp: Employment): string {
  const parts: string[] = []
  if (emp.department) parts.push(emp.department.name)
  if (emp.location) parts.push(emp.location.name)
  if (emp.manager) parts.push(`reports to ${emp.manager.full_name}`)
  return parts.join(' · ')
}

function onChangeSaved(result: { applied: boolean; effectiveDate: string }): void {
  notice.value = result.applied ? 'Change applied.' : `Change scheduled for ${result.effectiveDate}.`
  void load()
}

async function cancelChange(changeId: string): Promise<void> {
  if (!window.confirm('Cancel this scheduled change?')) return
  busy.value = true
  error.value = null
  const { error: err } = await supabase.rpc('cancel_employment_change', { p_change_id: changeId })
  busy.value = false
  if (err) {
    error.value = err.message
    return
  }
  notice.value = 'Scheduled change cancelled.'
  await load()
}

// A scheduled departure keeps the person current until they are marked former.
const current = computed(() => employments.value.find((e) => departureState(e) !== 'former') ?? null)

function canStartDeparture(emp: Employment): boolean {
  return auth.can(emp.company_id, 'departure.start')
}

function offboardingPlanId(emp: Employment): string | null {
  return emp.plans.find((p) => p.kind === 'offboarding' && p.status === 'in_progress')?.id ?? null
}

function onDepartureScheduled(result: { planId: string; alreadyScheduled: boolean }): void {
  notice.value = result.alreadyScheduled
    ? 'Departure dates updated; the existing offboarding plan continues.'
    : 'Departure scheduled and the offboarding plan started.'
  void load()
}

/** The explicit act of becoming Former (complete_departure, migration 0010). */
async function markAsFormer(emp: Employment): Promise<void> {
  const ok = window.confirm(
    `Mark ${person.value?.full_name} as former at ${emp.company?.name}? Open offboarding tasks stay visible and can still be completed.`,
  )
  if (!ok) return
  busy.value = true
  error.value = null
  const { data, error: err } = await supabase.rpc('complete_departure', { p_employment_period_id: emp.id })
  busy.value = false
  if (err) {
    error.value = friendlyDepartureError(err.message)
    return
  }
  const open = (data as { open_tasks: number })?.open_tasks ?? 0
  notice.value =
    open > 0
      ? `Now former. ${open} offboarding ${open === 1 ? 'task is' : 'tasks are'} still open.`
      : 'Now former. The offboarding plan is complete.'
  await load()
}

function initials(name: string): string {
  return name.split(' ').map((p) => p[0] ?? '').slice(0, 2).join('')
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  // Scheduled changes whose date has arrived apply on the way in (idempotent).
  const due = await supabase.rpc('apply_due_employment_changes')
  if (due.error) console.error('Applying due employment changes failed:', due.error.message)
  const [personRes, empRes, grantRes, deptRes, locRes, peopleRes, typesRes] = await Promise.all([
    supabase.from('people').select('full_name, work_email, user_id').eq('id', personId).maybeSingle(),
    supabase
      .from('employment_periods')
      .select(
        `id, company_id, person_id, job_title, status, start_date, end_date, last_working_date,
         employment_type_key, department_id, location_id, manager_id,
         company:companies(name),
         department:departments(name),
         location:locations(name),
         manager:people!employment_periods_manager_id_fkey(id, full_name),
         plans!plans_employment_period_id_fkey(id, kind, status),
         employment_changes(id, effective_date, changes, reason, status)`,
      )
      .eq('person_id', personId)
      .order('start_date', { ascending: false }),
    supabase
      .from('access_grants')
      .select('company_id, company:companies(name), grant_capabilities(capability_key)')
      .eq('person_id', personId),
    supabase.from('departments').select('id, name'),
    supabase.from('locations').select('id, name'),
    supabase.from('people').select('id, full_name'),
    supabase.from('employment_types').select('key, label'),
  ])
  lookups.value = {
    departments: Object.fromEntries((deptRes.data ?? []).map((d) => [d.id, d.name])),
    locations: Object.fromEntries((locRes.data ?? []).map((l) => [l.id, l.name])),
    people: Object.fromEntries((peopleRes.data ?? []).map((p) => [p.id, p.full_name])),
    employmentTypes: Object.fromEntries((typesRes.data ?? []).map((t) => [t.key, t.label])),
  }
  if (personRes.error || !personRes.data) {
    error.value = 'Person not found or not visible with your access.'
    loading.value = false
    return
  }
  person.value = personRes.data
  employments.value = (empRes.data ?? []) as Employment[]
  grants.value = (grantRes.data ?? []) as Grant[]
  loading.value = false
}

async function addEmployment(): Promise<void> {
  if (!empForm.value.jobTitle.trim() || !empForm.value.companyId) {
    error.value = 'Choose a company and enter a job title.'
    return
  }
  busy.value = true
  error.value = null
  const status =
    empForm.value.startDate > new Date().toISOString().slice(0, 10) ? 'pre_start' : 'active'
  const { error: err } = await supabase.from('employment_periods').insert({
    person_id: personId,
    company_id: empForm.value.companyId,
    job_title: empForm.value.jobTitle.trim(),
    employment_type_key: empForm.value.employmentType,
    status,
    start_date: empForm.value.startDate,
  })
  busy.value = false
  if (err) {
    error.value = /no_overlapping_employment/.test(err.message)
      ? 'This person already has an open employment period — schedule its departure and mark them former first (a transfer ends one period and starts the next).'
      : err.message
    return
  }
  showAddEmployment.value = false
  notice.value = 'Employment added.'
  await load()
}

onMounted(async () => {
  const [companiesRes, typesRes] = await Promise.all([
    supabase.from('companies').select('id, name').eq('kind', 'company').is('archived_at', null).order('name'),
    supabase.from('employment_types').select('key, label').is('archived_at', null).order('sort_order'),
  ])
  companies.value = companiesRes.data ?? []
  employmentTypes.value = typesRes.data ?? []
  if (companies.value[0]) empForm.value.companyId = companies.value[0].id
  await load()
})
</script>

<template>
  <div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <div v-if="loading" class="empty">Loading profile…</div>

    <template v-else-if="person">
      <div class="profile-head">
        <span class="avatar big" aria-hidden="true">{{ initials(person.full_name) }}</span>
        <div>
          <div class="eyebrow">Employee profile</div>
          <h1>{{ person.full_name }}</h1>
          <p class="meta">
            {{ person.work_email ?? 'no work email' }} ·
            {{ current ? `${current.job_title} · ${current.company?.name}` : 'no current employment' }}
            <template v-if="current?.manager"> · Manager: {{ current.manager.full_name }}</template>
            <span class="badge" :class="person.user_id ? 'green' : ''">
              {{ person.user_id ? 'has sign-in account' : 'no account — record only' }}
            </span>
          </p>
        </div>
        <router-link
          class="button secondary"
          :to="{ name: 'access-editor', params: { personId } }"
        >
          Manage access
        </router-link>
      </div>

      <div class="grid-two">
        <div class="card">
          <div class="card-head">
            <div>
              <h2>Employment history</h2>
              <p>Transfers and rehires add periods; history is never overwritten.</p>
            </div>
            <button
              v-if="auth.isAdmin"
              class="button secondary"
              type="button"
              @click="showAddEmployment = !showAddEmployment"
            >
              Add employment
            </button>
          </div>

          <form v-if="showAddEmployment" class="add-emp" novalidate @submit.prevent="addEmployment">
            <div class="field">
              <label for="emp-company">Company</label>
              <select id="emp-company" v-model="empForm.companyId">
                <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
              </select>
            </div>
            <div class="field">
              <label for="emp-title">Job title</label>
              <input id="emp-title" v-model="empForm.jobTitle" maxlength="120" />
            </div>
            <div class="field">
              <label for="emp-type">Type</label>
              <select id="emp-type" v-model="empForm.employmentType">
                <option v-for="t in employmentTypes" :key="t.key" :value="t.key">{{ t.label }}</option>
              </select>
            </div>
            <div class="field">
              <label for="emp-start">Start date</label>
              <input id="emp-start" v-model="empForm.startDate" type="date" />
            </div>
            <button class="button" type="submit" :disabled="busy">Save</button>
          </form>

          <div v-if="!employments.length" class="empty">
            No employment recorded. Add the first period to place them in a company.
          </div>
          <div v-for="emp in employments" :key="emp.id" class="emp-row">
            <div class="row-text">
              <strong>{{ emp.job_title }} · {{ emp.company?.name }}</strong>
              <small>
                {{ emp.start_date }} → {{ emp.end_date ?? 'present' }}
                <template v-if="emp.employment_type_key"> · {{ emp.employment_type_key.replace('_', ' ') }}</template>
              </small>
              <small v-if="employmentFacts(emp)" class="facts">{{ employmentFacts(emp) }}</small>
              <small
                v-for="c in pendingChanges(emp)"
                :key="c.id"
                class="pending-change"
              >
                Scheduled {{ c.effective_date }}: {{ describeChanges(c.changes, lookups) }}
                <template v-if="c.reason"> — {{ c.reason }}</template>
                <button
                  v-if="canEditEmployment(emp)"
                  class="link-button"
                  type="button"
                  :disabled="busy"
                  @click="cancelChange(c.id)"
                >
                  Cancel
                </button>
              </small>
              <small v-if="departureState(emp) === 'departing'" class="departing">
                Departing · last day {{ emp.last_working_date ?? emp.end_date }}
                <template v-if="offboardingPlanId(emp)">
                  ·
                  <router-link :to="{ name: 'offboarding-plan', params: { planId: offboardingPlanId(emp)! } }">
                    Open offboarding plan
                  </router-link>
                </template>
              </small>
            </div>
            <span class="badge" :class="emp.status === 'active' ? 'green' : emp.status === 'former' ? '' : 'blue'">
              {{ emp.status.replace('_', ' ') }}
            </span>
            <button
              v-if="canEditEmployment(emp) && departureState(emp) !== 'former'"
              class="button secondary small-btn"
              type="button"
              :disabled="busy"
              @click="changeDialog?.open(emp as ChangeTarget, person.full_name)"
            >
              Schedule change
            </button>
            <template v-if="canStartDeparture(emp)">
              <button
                v-if="departureState(emp) === 'employed'"
                class="button secondary small-btn"
                type="button"
                :disabled="busy"
                @click="departureDialog?.open(emp, person.full_name)"
              >
                Schedule departure
              </button>
              <button
                v-else-if="departureState(emp) === 'departing'"
                class="button secondary small-btn"
                type="button"
                :disabled="busy"
                @click="markAsFormer(emp)"
              >
                Mark as former
              </button>
            </template>
          </div>
        </div>

        <ScheduleDepartureDialog ref="departureDialog" @scheduled="onDepartureScheduled" />
        <ScheduleChangeDialog ref="changeDialog" @saved="onChangeSaved" />

        <div class="right-column">
          <div class="card">
            <div class="card-head">
              <div>
                <h2>Access</h2>
                <p>Grants are per company and separate from employment.</p>
              </div>
            </div>
            <div v-if="!grants.length" class="empty">No capabilities granted in any company.</div>
            <div v-for="g in grants" :key="g.company_id" class="emp-row">
              <div class="row-text">
                <strong>{{ g.company?.name }}</strong>
                <small>{{ g.grant_capabilities.length }} capabilities</small>
              </div>
              <router-link
                class="button secondary small-btn"
                :to="{ name: 'access-editor', params: { personId }, query: { company: g.company_id } }"
              >
                Edit
              </router-link>
            </div>
          </div>

          <CompensationCard :person-id="personId" :periods="employments" />
          <DocumentsCard :person-id="personId" :companies="personCompanies" />
          <DocumentRequestsCard :person-id="personId" :companies="personCompanies" />
          <PrivateDetailsCard :person-id="personId" />
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.profile-head { display: flex; align-items: center; gap: 18px; margin-bottom: 26px; flex-wrap: wrap; }
.profile-head h1 { margin: 6px 0; }
.profile-head .meta { margin: 0; color: var(--muted); font-size: 12px; display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.avatar.big { width: 62px; height: 62px; font-size: 20px; }
.grid-two { display: grid; grid-template-columns: minmax(0, 1.5fr) minmax(260px, 1fr); gap: 22px; }
@media (max-width: 900px) { .grid-two { grid-template-columns: 1fr; } }
.right-column { display: grid; gap: 22px; align-content: start; }
.emp-row { display: flex; align-items: center; gap: 13px; padding: 15px 24px; border-top: 1px solid #edf0eb; }
.row-text { flex: 1; min-width: 0; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.row-text .departing { color: var(--amber); font-weight: 550; }
.row-text .facts { color: var(--ink); opacity: 0.8; }
.row-text .pending-change { color: var(--green); }
.link-button { border: 0; background: none; color: var(--red); font-size: 10px; padding: 0 0 0 6px; cursor: pointer; text-decoration: underline; }
.row-text .departing a { color: var(--green); text-decoration: none; }
.row-text .departing a:hover { text-decoration: underline; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.add-emp { padding: 18px 24px; border-top: 1px solid var(--line); background: #fafbf8; display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
.add-emp .button { grid-column: 2; justify-self: end; }
@media (max-width: 560px) { .add-emp { grid-template-columns: 1fr; } .add-emp .button { grid-column: 1; } }
.notice { display: block; padding: 12px 15px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin-bottom: 16px; }
</style>
