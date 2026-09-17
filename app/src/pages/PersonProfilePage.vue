<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import PrivateDetailsCard from '@/components/PrivateDetailsCard.vue'
import EditPersonDialog, { type PersonBasics } from '@/components/EditPersonDialog.vue'
import ScheduleDepartureDialog from '@/components/ScheduleDepartureDialog.vue'
import ScheduleChangeDialog, { type ChangeTarget } from '@/components/ScheduleChangeDialog.vue'
import CorrectEmploymentDialog, { type CorrectTarget } from '@/components/CorrectEmploymentDialog.vue'
import TransferDialog from '@/components/TransferDialog.vue'
import CompensationCard from '@/components/CompensationCard.vue'
import LeaveCard from '@/components/LeaveCard.vue'
import AvatarUpload from '@/components/AvatarUpload.vue'
import DocumentsCard from '@/components/DocumentsCard.vue'
import DocumentRequestsCard from '@/components/DocumentRequestsCard.vue'
import PersonEquipmentCard from '@/components/PersonEquipmentCard.vue'
import { describeChanges, type Lookups } from '@/lib/employmentChanges'
import { departureState, friendlyDepartureError } from '@/lib/departure'
import { tenureLabel } from '@/lib/tenure'
import { todayDb } from '@/lib/compensation'
import { deliverNotifications } from '@/lib/notificationsApi'

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
  // Set once a transfer is scheduled or done (plan 035a).
  transferred_to_period_id: string | null
}
type Grant = {
  company_id: string
  company: { name: string } | null
  grant_capabilities: { capability_key: string }[]
}

const route = useRoute()
const auth = useAuthStore()
const dialogs = useDialogStore()
const personId = route.params.personId as string

type Person = PersonBasics & { user_id: string | null; avatar_url: string | null }
const person = ref<Person | null>(null)
const editDialog = ref<InstanceType<typeof EditPersonDialog> | null>(null)
// Mirrors can_edit_person (RLS): admins, employment.edit where they are employed,
// or anywhere when the record has no employment yet.
const canEditBasics = computed(() =>
  employments.value.length
    ? employments.value.some((e) => auth.can(e.company_id, 'employment.edit'))
    : auth.canAnywhere('employment.edit'),
)
function onBasicsSaved(saved: PersonBasics): void {
  if (person.value) person.value = { ...person.value, ...saved }
  notice.value = 'Details saved.'
}
const employments = ref<Employment[]>([])
const grants = ref<Grant[]>([])
// Companies the person has (had) employment with — where their documents may live.
const personCompanies = computed(() => {
  const seen = new Map<string, { id: string; name: string }>()
  for (const e of employments.value) if (!seen.has(e.company_id)) seen.set(e.company_id, { id: e.company_id, name: e.company?.name ?? '' })
  return [...seen.values()]
})
const personCompanyIds = computed(() => personCompanies.value.map((c) => c.id))
// The pickers the correction dialog offers, already loaded for the facts strip.
const peopleOptions = ref<{ id: string; name: string }[]>([])
const typeOptions = ref<{ key: string; label: string }[]>([])
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
// Adding a period needs employment.edit in the chosen company (RLS); a
// person whose employment has all ended is rehired — same record, new period.
const editableCompanies = computed(() => companies.value.filter((c) => auth.can(c.id, 'employment.edit')))
const isRehire = computed(() => employments.value.length > 0 && employments.value.every((e) => departureState(e) === 'former'))
// Periods never overlap, former ones included: a rehire starts after the last end date.
const lastEndDate = computed(() => employments.value.map((e) => e.end_date).filter((d): d is string => !!d).sort().at(-1) ?? null)
function nextAvailableStart(): string {
  const today = new Date().toISOString().slice(0, 10)
  if (!lastEndDate.value || lastEndDate.value < today) return today
  const next = new Date(`${lastEndDate.value}T00:00:00Z`)
  next.setUTCDate(next.getUTCDate() + 1)
  return next.toISOString().slice(0, 10)
}
const departureDialog = ref<InstanceType<typeof ScheduleDepartureDialog> | null>(null)
const changeDialog = ref<InstanceType<typeof ScheduleChangeDialog> | null>(null)
const correctDialog = ref<InstanceType<typeof CorrectEmploymentDialog> | null>(null)
const transferDialog = ref<InstanceType<typeof TransferDialog> | null>(null)
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

function onTransferred(result: { applied: boolean; effectiveDate: string; companyName: string }): void {
  notice.value = result.applied
    ? `Transferred to ${result.companyName}. The previous employment is on record as former.`
    : `Transfer to ${result.companyName} scheduled for ${result.effectiveDate}; the current employment continues until then.`
  void load()
}

function onChangeSaved(result: { applied: boolean; effectiveDate: string }): void {
  notice.value = result.applied ? 'Change applied.' : `Change scheduled for ${result.effectiveDate}.`
  void load()
}

function onCorrected(result: { startDate: string; jobTitle: string }): void {
  notice.value = `Record corrected — ${result.jobTitle} from ${result.startDate}.`
  void load()
}

async function cancelChange(changeId: string): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: 'Cancel this scheduled change?',
    hint: 'The employment stays as it is today; the change is kept in history as cancelled.',
    confirmLabel: 'Cancel the change',
    cancelLabel: 'Keep it',
  })
  if (!ok) return
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

// The facts strip under the name: what you would ask about this person first.
const leaveLeft = ref<number | null>(null)
const facts = computed(() => {
  const c = current.value
  if (!c) return []
  const list: { label: string; value: string; sub?: string }[] = [
    { label: 'Started', value: c.start_date, sub: tenureLabel(c.start_date, c.end_date, todayDb()) },
  ]
  if (c.department) list.push({ label: 'Department', value: c.department.name })
  if (c.location) list.push({ label: 'Location', value: c.location.name })
  if (c.manager) list.push({ label: 'Reports to', value: c.manager.full_name })
  if (c.employment_type_key) list.push({ label: 'Type', value: c.employment_type_key.replace('_', '-').replace(/^./, (ch) => ch.toUpperCase()) })
  if (leaveLeft.value !== null) list.push({ label: 'Leave left', value: `${leaveLeft.value} days`, sub: String(new Date().getUTCFullYear()) })
  return list
})

async function loadLeaveLeft(): Promise<void> {
  const c = current.value
  if (!c) return
  const { data } = await supabase.rpc('leave_balance', { p_person_id: personId, p_company_id: c.company_id, p_year: Number(todayDb().slice(0, 4)) })
  const b = data as { exists?: boolean; remaining?: number } | null
  leaveLeft.value = b?.exists ? Number(b.remaining ?? 0) : null
}

function tenure(emp: Employment): string {
  return tenureLabel(emp.start_date, emp.end_date, todayDb())
}

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
  void deliverNotifications()
  void load()
}

/** The way back from a scheduled departure (cancel_departure, migration 0040). */
async function cancelDeparture(emp: Employment): Promise<void> {
  const answer = await dialogs.askReason({
    title: `Cancel ${person.value?.full_name}'s departure?`,
    hint: 'The end date goes, the offboarding checklist is closed as cancelled, the person stays employed.',
    required: false,
    confirmLabel: 'Cancel departure',
  })
  if (!answer) return
  busy.value = true
  error.value = null
  const { error: err } = await supabase.rpc('cancel_departure', { p_employment_period_id: emp.id, p_reason: answer.reason || undefined })
  busy.value = false
  if (err) {
    error.value = friendlyDepartureError(err.message)
    return
  }
  notice.value = 'Departure cancelled. The person stays employed; the checklist is on record as cancelled.'
  await load()
}

/** The explicit act of becoming Former (complete_departure, migration 0010). */
async function markAsFormer(emp: Employment): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Mark ${person.value?.full_name} as former at ${emp.company?.name}?`,
    hint: 'Open offboarding tasks stay visible and can still be completed.',
    confirmLabel: 'Mark as former',
    danger: true,
  })
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
  void deliverNotifications()
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
    supabase.from('people').select('id, full_name, preferred_name, work_email, personal_email, phone, user_id, avatar_url').eq('id', personId).maybeSingle(),
    supabase
      .from('employment_periods')
      .select(
        `id, company_id, person_id, job_title, status, start_date, end_date, last_working_date,
         employment_type_key, department_id, location_id, manager_id, transferred_to_period_id,
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
  peopleOptions.value = (peopleRes.data ?? []).map((p) => ({ id: p.id, name: p.full_name }))
  typeOptions.value = typesRes.data ?? []
  if (personRes.error || !personRes.data) {
    error.value = 'Person not found or not visible with your access.'
    loading.value = false
    return
  }
  person.value = personRes.data
  employments.value = (empRes.data ?? []) as Employment[]
  void loadLeaveLeft()
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
    if (/no_overlapping_employment/.test(err.message)) {
      error.value = isRehire.value
        ? `Their previous employment runs until ${lastEndDate.value ?? 'its end date'}; start the new period after that.`
        : 'This person already has an open employment period — schedule its departure and mark them former first (a transfer ends one period and starts the next).'
    } else {
      error.value = err.message
    }
    return
  }
  showAddEmployment.value = false
  notice.value = isRehire.value ? 'Rehired — a new employment period starts; the old one stays on record.' : 'Employment added.'
  await load()
}

/** A rehire starts from the last employment: same company, title and type, dated today. */
function toggleAddEmployment(): void {
  if (!showAddEmployment.value) {
    const last = [...employments.value].sort((a, b) => b.start_date.localeCompare(a.start_date))[0]
    const company = last && editableCompanies.value.some((c) => c.id === last.company_id) ? last.company_id : editableCompanies.value[0]?.id ?? ''
    empForm.value = {
      companyId: company,
      jobTitle: isRehire.value && last ? last.job_title : '',
      employmentType: (isRehire.value && last?.employment_type_key) || 'full_time',
      startDate: nextAvailableStart(),
    }
  }
  showAddEmployment.value = !showAddEmployment.value
}

onMounted(async () => {
  const [companiesRes, typesRes] = await Promise.all([
    supabase.from('companies').select('id, name').is('archived_at', null).order('name'),
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
      <header class="profile-head card">
        <div class="hero">
          <AvatarUpload
            :person-id="personId"
            :name="person.full_name"
            :path="person.avatar_url"
            :editable="auth.personId === personId || editableCompanies.length > 0"
            @changed="(p) => { if (person) person = { ...person, avatar_url: p }; if (auth.personId === personId) auth.avatarPath = p }"
          />
          <div class="who">
            <div class="eyebrow">Employee profile</div>
            <h1>{{ person.full_name }}</h1>
            <p class="meta">
              <strong v-if="current">{{ current.job_title }}</strong>
              <template v-if="current?.company"> · {{ current.company.name }}</template>
              <template v-if="!current">No current employment</template>
              <a v-if="person.work_email" :href="`mailto:${person.work_email}`" class="mail">{{ person.work_email }}</a>
              <span v-if="person.personal_email" class="contact" data-testid="personal-email">{{ person.personal_email }}</span>
              <span v-if="person.phone" class="contact" data-testid="personal-phone">{{ person.phone }}</span>
              <span v-if="current" class="badge" :class="current.status === 'active' ? 'green' : current.status === 'former' ? '' : 'blue'">{{ current.status.replace('_', ' ') }}</span>
              <span class="badge" :class="person.user_id ? 'green' : ''">
                {{ person.user_id ? 'has sign-in account' : 'no account — record only' }}
              </span>
            </p>
          </div>
          <div class="hero-actions">
            <button v-if="canEditBasics" class="button secondary" type="button" data-testid="edit-details" @click="editDialog?.open(person)">
              Edit details
            </button>
            <router-link class="button secondary" :to="{ name: 'access-editor', params: { personId } }">Manage access</router-link>
          </div>
        </div>
        <dl v-if="facts.length" class="facts-strip">
          <div v-for="f in facts" :key="f.label" class="fact">
            <dt>{{ f.label }}</dt>
            <dd>{{ f.value }}<small v-if="f.sub">{{ f.sub }}</small></dd>
          </div>
        </dl>
      </header>
      <div class="grid-two">
        <div class="main-column">
        <div class="card">
          <div class="card-head">
            <div>
              <h2>Employment history</h2>
              <p>Transfers and rehires add periods; history is never overwritten.</p>
            </div>
            <button
              v-if="editableCompanies.length"
              class="button secondary"
              type="button"
              @click="toggleAddEmployment"
            >
              {{ isRehire ? 'Rehire' : 'Add employment' }}
            </button>
          </div>

          <form v-if="showAddEmployment" class="add-emp" novalidate @submit.prevent="addEmployment">
            <div class="field">
              <label for="emp-company">Company</label>
              <select id="emp-company" v-model="empForm.companyId">
                <option v-for="c in editableCompanies" :key="c.id" :value="c.id">{{ c.name }}</option>
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
          <div v-for="emp in employments" :key="emp.id" class="emp-row timeline" :class="{ current: emp.id === current?.id }">
            <span class="dot" aria-hidden="true"></span>
            <div class="row-text">
              <strong>{{ emp.job_title }} · {{ emp.company?.name }}</strong>
              <small>
                {{ emp.start_date }} → {{ emp.end_date ?? 'present' }} · {{ tenure(emp) }}
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
              <small v-if="departureState(emp) === 'departing' && emp.transferred_to_period_id" class="departing">
                Transferring · last day here {{ emp.last_working_date ?? emp.end_date }}
              </small>
              <small v-else-if="departureState(emp) === 'departing'" class="departing">
                Departing · last day {{ emp.last_working_date ?? emp.end_date }}
                <template v-if="offboardingPlanId(emp)">
                  ·
                  <router-link :to="{ name: 'offboarding-plan', params: { planId: offboardingPlanId(emp)! } }">
                    Open offboarding plan
                  </router-link>
                </template>
              </small>
            </div>
            <div class="row-actions">
            <span class="badge" :class="emp.status === 'active' ? 'green' : emp.status === 'former' ? '' : 'blue'">
              {{ emp.status.replace('_', ' ') }}
            </span>
            <button
              v-if="canEditEmployment(emp)"
              class="button secondary small-btn"
              type="button"
              :disabled="busy"
              @click="correctDialog?.open(emp as CorrectTarget, person.full_name)"
            >
              Correct
            </button>
            <button
              v-if="canEditEmployment(emp) && departureState(emp) !== 'former'"
              class="button secondary small-btn"
              type="button"
              :disabled="busy"
              @click="changeDialog?.open(emp as ChangeTarget, person.full_name)"
            >
              Schedule change
            </button>
            <button
              v-if="canEditEmployment(emp) && departureState(emp) !== 'former' && !emp.transferred_to_period_id"
              class="button secondary small-btn"
              type="button"
              :disabled="busy"
              @click="transferDialog?.open(emp, person.full_name)"
            >
              Transfer
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
              <template v-else-if="departureState(emp) === 'departing' && !emp.transferred_to_period_id">
                <button
                  class="button secondary small-btn"
                  type="button"
                  :disabled="busy"
                  data-testid="cancel-departure"
                  @click="cancelDeparture(emp)"
                >
                  Cancel departure
                </button>
                <button
                  class="button secondary small-btn"
                  type="button"
                  :disabled="busy"
                  @click="markAsFormer(emp)"
                >
                  Mark as former
                </button>
              </template>
            </template>
            </div>
          </div>
        </div>

        <LeaveCard :person-id="personId" :person-name="person.full_name" />
        <CompensationCard :person-id="personId" :periods="employments" />
        <PersonEquipmentCard :person-id="personId" :companies="personCompanies" />
        </div>
        <ScheduleDepartureDialog ref="departureDialog" @scheduled="onDepartureScheduled" />
        <ScheduleChangeDialog ref="changeDialog" @saved="onChangeSaved" />
        <CorrectEmploymentDialog ref="correctDialog" :employment-types="typeOptions" :people="peopleOptions" @corrected="onCorrected" />
        <TransferDialog ref="transferDialog" @transferred="onTransferred" />
        <EditPersonDialog ref="editDialog" @saved="onBasicsSaved" />

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

          <DocumentsCard :person-id="personId" :companies="personCompanies" />
          <DocumentRequestsCard :person-id="personId" :companies="personCompanies" />
          <PrivateDetailsCard :person-id="personId" :company-ids="personCompanyIds" />
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.profile-head { margin-bottom: 22px; background: linear-gradient(135deg, #ffffff 0%, #f7faf6 100%); }
.hero { display: flex; align-items: center; gap: 22px; padding: 26px 28px; flex-wrap: wrap; }
.who { flex: 1; min-width: 240px; }
.profile-head h1 { margin: 6px 0 8px; font-size: 32px; }
.profile-head .meta { margin: 0; color: var(--muted); font-size: 13px; display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.profile-head .meta strong { color: var(--ink); font-weight: 600; }
.profile-head .mail { color: var(--green); text-decoration: none; }
.profile-head .mail:hover { text-decoration: underline; }
.profile-head .contact { color: var(--muted); }
.hero-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.avatar.big { width: 76px; height: 76px; font-size: 24px; background: linear-gradient(145deg, #dbe8d2, #b9d3c1); box-shadow: 0 10px 24px -12px rgba(22, 36, 31, 0.5), inset 0 1px 0 rgba(255, 255, 255, 0.8); }
.facts-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 0; margin: 0; border-top: 1px solid var(--line); background: #fff; }
.fact { padding: 14px 22px; border-right: 1px solid var(--line); }
.fact:last-child { border-right: 0; }
.fact dt { font-size: 11px; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); font-weight: 650; }
.fact dd { margin: 4px 0 0; font-size: 14px; font-weight: 600; color: var(--ink); }
.fact dd small { display: block; font-size: 11px; color: var(--muted); font-weight: 500; margin-top: 2px; text-transform: none; }
.grid-two { display: grid; grid-template-columns: minmax(0, 1.45fr) minmax(300px, 1fr); gap: 22px; align-items: start; }
@media (max-width: 900px) { .grid-two { grid-template-columns: 1fr; } }
.main-column, .right-column { display: grid; gap: 22px; align-content: start; min-width: 0; }
.emp-row { display: flex; align-items: center; gap: 13px; padding: 15px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.row-actions { display: flex; align-items: center; gap: 7px; flex-wrap: wrap; justify-content: flex-end; margin-left: auto; }
.emp-row.timeline { position: relative; padding-left: 46px; }
.emp-row.timeline::before { content: ''; position: absolute; left: 27px; top: 0; bottom: 0; width: 2px; background: var(--line); }
.emp-row.timeline:first-of-type::before { top: 50%; }
.emp-row.timeline:last-of-type::before { bottom: 50%; }
.emp-row.timeline .dot { position: absolute; left: 22px; top: 50%; width: 12px; height: 12px; border-radius: 50%; transform: translateY(-50%); background: #fff; border: 2px solid var(--line-strong); box-shadow: 0 0 0 3px #fff; }
.emp-row.timeline.current .dot { border-color: var(--green-bright); background: var(--green-bright); box-shadow: 0 0 0 3px #fff, 0 0 0 6px rgba(47, 122, 99, 0.18); }
.row-text { flex: 1 1 240px; min-width: 0; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.row-text .departing { color: var(--amber); font-weight: 550; }
.row-text .facts { color: var(--ink); opacity: 0.8; }
.row-text .pending-change { color: var(--green); }
.link-button { border: 0; background: none; color: var(--red); font-size: 11px; padding: 0 0 0 6px; cursor: pointer; text-decoration: underline; }
.row-text .departing a { color: var(--green); text-decoration: none; }
.row-text .departing a:hover { text-decoration: underline; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.add-emp { padding: 18px 24px; border-top: 1px solid var(--line); background: #fafbf8; display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
.add-emp .button { grid-column: 2; justify-self: end; }
@media (max-width: 560px) { .add-emp { grid-template-columns: 1fr; } .add-emp .button { grid-column: 1; } }
.notice { display: block; padding: 12px 15px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin-bottom: 16px; }
</style>
