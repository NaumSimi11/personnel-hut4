<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { deliverNotifications } from '@/lib/notificationsApi'
import type { Json } from '@/types/database'
import {
  addDepartment as addDepartmentRow,
  EMPTY_STRUCTURE,
  loadCompanyStructure,
  withOption,
  type Structure,
} from '@/lib/companyStructure'
import {
  emptyForm,
  employeeInput,
  hiddenSectionProblem,
  messageFor,
  prefillFromApplication,
  sectionsFor,
  shouldStartOnboarding,
  successLine,
  toPayload,
  type ApplicationTarget,
  type CreateResult,
  type EmployeeForm,
} from '@/lib/employeeForm'
import PrivateDetailsFields, { type PrivateDetailsForm } from '@/components/PrivateDetailsFields.vue'

/**
 * One employee, one screen (plan 046): identity, employment, personal &
 * emergency (personal.view holders), pay (salary.propose holders) — written
 * by create_employee (migrations 0038 / 0039) in one transaction, with the
 * onboarding checklist started. Opened plain from People & access, or
 * pre-filled from an application, where it is the hire (confirm_hire's
 * rules: offer stage only, idempotent, checklist always).
 */
const emit = defineEmits<{ created: [] }>()

type Option = { id: string; name: string }
type Keyed = { key: string; label: string }

const auth = useAuthStore()
const dialog = ref<HTMLDialogElement | null>(null)
const form = ref<EmployeeForm>(emptyForm(todayDb()))
const target = ref<ApplicationTarget | null>(null)
const companies = ref<Option[]>([])
const structure = ref<Structure>(EMPTY_STRUCTURE)
const people = ref<Option[]>([])
const employmentTypes = ref<Keyed[]>([])
const payBases = ref<Keyed[]>([])
const referenceLoaded = ref(false)
const newDepartment = ref('')
const addingDepartment = ref(false)
const onboardingTouched = ref(false)
const error = ref<string | null>(null)
const busy = ref(false)
const result = ref<{ personId: string; planId: string | null; line: string } | null>(null)

const isHire = computed(() => target.value?.applicationId !== undefined)
const sections = computed(() => sectionsFor(auth, form.value.companyId))
const canAddDepartment = computed(() => !!form.value.companyId && auth.can(form.value.companyId, 'employment.edit'))

/** The private fields as their own object, so the shared inputs can bind to them. */
const privatePart = computed<PrivateDetailsForm>({
  get: () => ({
    birthDate: form.value.birthDate,
    addressLine: form.value.addressLine,
    nationalId: form.value.nationalId,
    bankName: form.value.bankName,
    bankAccountNumber: form.value.bankAccountNumber,
    emergencyName: form.value.emergencyName,
    emergencyRelationship: form.value.emergencyRelationship,
    emergencyPhone: form.value.emergencyPhone,
    notes: form.value.notes,
  }),
  set: (next) => {
    form.value = { ...form.value, ...next }
  },
})

async function open(t?: ApplicationTarget): Promise<void> {
  const today = todayDb()
  target.value = t ?? null
  form.value = t ? prefillFromApplication(t, today) : emptyForm(today)
  onboardingTouched.value = false
  error.value = null
  result.value = null
  newDepartment.value = ''
  dialog.value?.showModal()
  try {
    // Reference data changes rarely: once per mount is enough.
    if (!referenceLoaded.value) await loadReference()
    if (!form.value.companyId && companies.value[0]) form.value = { ...form.value, companyId: companies.value[0].id }
    await loadStructure(form.value.companyId)
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not load the form.'
  }
}
defineExpose({ open })

async function loadReference(): Promise<void> {
  const [companiesRes, typesRes, basesRes, peopleRes] = await Promise.all([
    supabase.from('companies').select('id, name').is('archived_at', null).order('name'),
    supabase.from('employment_types').select('key, label').is('archived_at', null).order('sort_order'),
    supabase.from('pay_bases').select('key, label').order('sort_order'),
    supabase.from('people').select('id, full_name').is('archived_at', null).order('full_name'),
  ])
  const failed = companiesRes.error ?? typesRes.error ?? basesRes.error ?? peopleRes.error
  if (failed) {
    console.error('Add employee reference load failed:', failed.message)
    throw new Error('Could not load companies and reference data.')
  }
  // Only where this viewer may add: the RPC checks employment.edit again.
  companies.value = (companiesRes.data ?? []).filter((c) => auth.can(c.id, 'employment.edit'))
  employmentTypes.value = typesRes.data ?? []
  payBases.value = basesRes.data ?? []
  people.value = (peopleRes.data ?? []).map((p) => ({ id: p.id, name: p.full_name }))
  referenceLoaded.value = true
}

async function loadStructure(companyId: string): Promise<void> {
  structure.value = await loadCompanyStructure(companyId)
  const keepDept = structure.value.departments.some((d) => d.id === form.value.departmentId) ? form.value.departmentId : ''
  const keepLoc = structure.value.locations.some((l) => l.id === form.value.locationId) ? form.value.locationId : ''
  form.value = { ...form.value, departmentId: keepDept, locationId: keepLoc }
}

watch(
  () => form.value.companyId,
  (id, was) => {
    if (id !== was && was !== undefined) void loadStructure(id).catch((e: unknown) => (error.value = e instanceof Error ? e.message : String(e)))
  },
)
watch(
  () => form.value.startDate,
  (date) => {
    // A hire always gets its checklist; a plain add follows the date unless the person decided.
    if (!isHire.value && !onboardingTouched.value) form.value = { ...form.value, startOnboarding: shouldStartOnboarding(date, todayDb()) }
  },
)

/** HR may add the department the new hire belongs to, right here (0038 opened the structure to employment.edit). */
async function addDepartment(): Promise<void> {
  addingDepartment.value = true
  error.value = null
  try {
    const added = await addDepartmentRow(form.value.companyId, newDepartment.value)
    structure.value = { ...structure.value, departments: withOption(structure.value.departments, added) }
    form.value = { ...form.value, departmentId: added.id }
    newDepartment.value = ''
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not add the department.'
  } finally {
    addingDepartment.value = false
  }
}

async function submit(): Promise<void> {
  error.value = null
  const parsed = employeeInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  const hidden = hiddenSectionProblem(parsed.data, sections.value)
  if (hidden) {
    error.value = hidden
    return
  }
  busy.value = true
  const payload = toPayload(parsed.data, { applicationId: target.value?.applicationId })
  const { data, error: rpcErr } = await supabase.rpc('create_employee', { p: payload as Json })
  busy.value = false
  if (rpcErr) {
    error.value = messageFor(rpcErr)
    return
  }
  const created = data as CreateResult & { person_id: string }
  result.value = { personId: created.person_id, planId: created.plan_id, line: successLine(created) }
  // The hire raised its handover sends; send what can go now.
  void deliverNotifications()
  emit('created')
}

function close(): void {
  dialog.value?.close()
}
</script>

<template>
  <dialog ref="dialog" class="add-employee" aria-labelledby="add-employee-title" data-testid="add-employee-dialog">
    <div v-if="result" class="body">
      <div class="eyebrow">{{ isHire ? 'Hire confirmed' : 'Employee added' }}</div>
      <h2 id="add-employee-title">{{ isHire ? 'Hired.' : 'Added.' }} {{ result.line }}</h2>
      <p v-if="!result.planId" class="hint">No checklist was started{{ form.startOnboarding ? ' — check the onboarding template for this company' : '' }}.</p>
      <div class="actions">
        <router-link
          v-if="result.planId"
          class="button"
          :to="{ name: 'onboarding-plan', params: { planId: result.planId } }"
          data-testid="open-checklist"
          @click="close"
        >
          Open checklist
        </router-link>
        <router-link class="button secondary" :to="{ name: 'person', params: { personId: result.personId } }" data-testid="open-record" @click="close">
          Open record
        </router-link>
        <button class="button" type="button" @click="close">Done</button>
      </div>
    </div>

    <form v-else class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">{{ isHire ? 'Recruitment' : 'Employee records' }}</div>
      <h2 id="add-employee-title">{{ isHire ? `Confirm the hire of ${target?.candidateName || 'this candidate'}.` : 'Add an employee.' }}</h2>
      <p class="hint">
        Everything on one screen; only the name, company, title and start date are required. The record is
        created with its employment{{ form.startOnboarding ? ' and the onboarding checklist' : '' }} in one step
        — no sign-in account; invite them separately when they should have access.
      </p>

      <fieldset class="section">
        <legend>Identity</legend>
        <div class="grid">
          <div class="field">
            <label for="ae-name">Full name</label>
            <input id="ae-name" v-model="form.fullName" required maxlength="120" />
          </div>
          <div class="field">
            <label for="ae-preferred">Preferred name</label>
            <input id="ae-preferred" v-model="form.preferredName" maxlength="60" />
          </div>
          <div class="field">
            <label for="ae-work-email">Work email</label>
            <input id="ae-work-email" v-model="form.workEmail" type="email" maxlength="320" />
          </div>
          <div class="field">
            <label for="ae-personal-email">Personal email</label>
            <input id="ae-personal-email" v-model="form.personalEmail" type="email" maxlength="320" />
          </div>
          <div class="field">
            <label for="ae-phone">Personal phone</label>
            <input id="ae-phone" v-model="form.phone" maxlength="40" />
          </div>
        </div>
      </fieldset>

      <fieldset class="section">
        <legend>Employment</legend>
        <div class="grid">
          <div class="field">
            <label for="ae-company">Employing company</label>
            <select id="ae-company" v-model="form.companyId" :disabled="isHire">
              <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
            </select>
          </div>
          <div class="field">
            <label for="ae-title">Job title</label>
            <input id="ae-title" v-model="form.jobTitle" required maxlength="120" />
          </div>
          <div class="field">
            <label for="ae-department">Department</label>
            <select id="ae-department" v-model="form.departmentId">
              <option value="">Not set</option>
              <option v-for="d in structure.departments" :key="d.id" :value="d.id">{{ d.name }}</option>
            </select>
            <div v-if="canAddDepartment" class="inline-add">
              <input
                id="ae-new-department"
                v-model="newDepartment"
                maxlength="80"
                placeholder="New department"
                aria-label="New department"
                @keydown.enter.prevent="addDepartment"
              />
              <button class="button secondary small-btn" type="button" :disabled="addingDepartment" @click="addDepartment">Add</button>
            </div>
          </div>
          <div class="field">
            <label for="ae-location">Location</label>
            <select id="ae-location" v-model="form.locationId">
              <option value="">Not set</option>
              <option v-for="l in structure.locations" :key="l.id" :value="l.id">{{ l.name }}</option>
            </select>
          </div>
          <div class="field">
            <label for="ae-type">Employment type</label>
            <select id="ae-type" v-model="form.employmentTypeKey">
              <option v-for="t in employmentTypes" :key="t.key" :value="t.key">{{ t.label }}</option>
            </select>
          </div>
          <div class="field">
            <label for="ae-manager">Manager</label>
            <select id="ae-manager" v-model="form.managerId">
              <option value="">No manager yet</option>
              <option v-for="p in people" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
          </div>
          <div class="field">
            <label for="ae-start">Start date</label>
            <input id="ae-start" v-model="form.startDate" type="date" required />
          </div>
          <div v-if="!isHire" class="field checkbox">
            <label for="ae-onboarding">
              <input
                id="ae-onboarding"
                v-model="form.startOnboarding"
                type="checkbox"
                @change="onboardingTouched = true"
              />
              Start the onboarding checklist
            </label>
            <small class="field-hint">On by default for a recent or upcoming start; off for a backfill.</small>
          </div>
          <p v-else class="field-hint hire-note">A confirmed hire always gets the onboarding checklist.</p>
        </div>
      </fieldset>

      <fieldset v-if="sections.personal" class="section" data-testid="section-personal">
        <legend>Personal &amp; emergency <span class="badge amber">Sensitive</span></legend>
        <PrivateDetailsFields v-model="privatePart" prefix="ae" />
      </fieldset>

      <fieldset v-if="sections.pay" class="section" data-testid="section-pay">
        <legend>Pay <span class="badge amber">Sensitive</span></legend>
        <p class="hint">Saved as a proposal from the start date; someone else approves it, as with any raise.</p>
        <div class="grid">
          <div class="field">
            <label for="ae-pay-amount">Amount</label>
            <input id="ae-pay-amount" v-model="form.payAmount" inputmode="decimal" placeholder="e.g. 1500" />
          </div>
          <div class="field">
            <label for="ae-pay-currency">Currency</label>
            <input id="ae-pay-currency" v-model="form.payCurrency" maxlength="3" class="currency" />
          </div>
          <div class="field">
            <label for="ae-pay-basis">Basis</label>
            <select id="ae-pay-basis" v-model="form.payBasisKey">
              <option v-for="b in payBases" :key="b.key" :value="b.key">{{ b.label }}</option>
            </select>
          </div>
          <div class="field">
            <label for="ae-pay-note">Note</label>
            <input id="ae-pay-note" v-model="form.payNote" maxlength="500" placeholder="e.g. Offer letter" />
          </div>
        </div>
      </fieldset>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="close">Cancel</button>
        <button class="button" type="submit" :disabled="busy">
          {{ busy ? (isHire ? 'Confirming…' : 'Creating…') : isHire ? 'Complete hire' : 'Create employee' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.add-employee {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(760px, calc(100vw - 36px));
  max-height: calc(100vh - 40px);
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.add-employee::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 14px; }
.section { border: 1px solid var(--line); border-radius: 12px; padding: 14px 18px 4px; margin: 0 0 14px; }
.section legend { font-size: 12px; font-weight: 700; padding: 0 6px; display: flex; align-items: center; gap: 8px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 620px) { .grid { grid-template-columns: 1fr; } }
.field.checkbox label { display: flex; align-items: center; gap: 8px; font-weight: 600; }
.field.checkbox input { width: auto; }
.field-hint { font-size: 11px; color: var(--muted); }
.hire-note { align-self: end; margin: 0 0 17px; }
.inline-add { display: flex; gap: 6px; margin-top: 6px; }
.inline-add input { flex: 1; min-width: 0; padding: 8px 10px; font-size: 12px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.currency { text-transform: uppercase; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 10px; flex-wrap: wrap; }
</style>
