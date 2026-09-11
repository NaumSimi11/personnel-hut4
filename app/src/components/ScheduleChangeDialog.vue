<script setup lang="ts">
import { ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { changeInput, diffChanges, type ChangeForm, type PeriodFields } from '@/lib/employmentChanges'

/**
 * Schedule a change to an employment period (plan 022): effective date,
 * new title / department / location / manager / type, and a reason. Dated
 * today or earlier it applies at once; later it waits. The database refuses
 * circular reporting lines and departments from other companies.
 */

export type ChangeTarget = PeriodFields & {
  id: string
  company_id: string
  person_id: string
  start_date: string
  company: { name: string } | null
}

type Option = { id: string; name: string }

const emit = defineEmits<{ saved: [result: { applied: boolean; effectiveDate: string }] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const target = ref<ChangeTarget | null>(null)
const personName = ref('')
const form = ref<ChangeForm>(empty())
const departments = ref<Option[]>([])
const locations = ref<Option[]>([])
const people = ref<Option[]>([])
const employmentTypes = ref<{ key: string; label: string }[]>([])
const error = ref<string | null>(null)
const busy = ref(false)

function empty(): ChangeForm {
  return {
    effectiveDate: new Date().toISOString().slice(0, 10),
    jobTitle: '',
    departmentId: '',
    locationId: '',
    managerId: '',
    employmentTypeKey: '',
    reason: '',
  }
}

async function loadOptions(companyId: string, personId: string): Promise<void> {
  const [deptRes, locRes, peopleRes, typesRes] = await Promise.all([
    supabase
      .from('departments')
      .select('id, name')
      .or(`company_id.eq.${companyId},company_id.is.null`)
      .is('archived_at', null)
      .order('name'),
    supabase
      .from('locations')
      .select('id, name')
      .or(`company_id.eq.${companyId},company_id.is.null`)
      .is('archived_at', null)
      .order('name'),
    supabase.from('people').select('id, full_name').is('archived_at', null).neq('id', personId).order('full_name'),
    supabase.from('employment_types').select('key, label').is('archived_at', null).order('sort_order'),
  ])
  departments.value = deptRes.data ?? []
  locations.value = locRes.data ?? []
  people.value = (peopleRes.data ?? []).map((p) => ({ id: p.id, name: p.full_name }))
  employmentTypes.value = typesRes.data ?? []
}

async function open(period: ChangeTarget, name: string): Promise<void> {
  target.value = period
  personName.value = name
  form.value = {
    ...empty(),
    jobTitle: period.job_title,
    departmentId: period.department_id ?? '',
    locationId: period.location_id ?? '',
    managerId: period.manager_id ?? '',
    employmentTypeKey: period.employment_type_key ?? '',
  }
  error.value = null
  dialog.value?.showModal()
  await loadOptions(period.company_id, period.person_id)
}
defineExpose({ open })

async function submit(): Promise<void> {
  if (!target.value) return
  error.value = null
  const parsed = changeInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  const changes = diffChanges(target.value, parsed.data)
  if (!Object.keys(changes).length) {
    error.value = 'Nothing has changed.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('schedule_employment_change', {
    p_period_id: target.value.id,
    p_effective_date: parsed.data.effectiveDate,
    p_changes: changes,
    p_reason: parsed.data.reason || undefined,
  })
  busy.value = false
  if (err) {
    error.value = /employment\.edit/.test(err.message)
      ? 'You need employment.edit in this company to change employment.'
      : err.message
    return
  }
  dialog.value?.close()
  emit('saved', { applied: (data as { applied: boolean })?.applied === true, effectiveDate: parsed.data.effectiveDate })
}
</script>

<template>
  <dialog ref="dialog" class="change-dialog" aria-labelledby="change-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Employment change</div>
      <h2 id="change-title">Change {{ personName || 'this' }}'s employment.</h2>
      <p class="hint">
        {{ target?.job_title }} · {{ target?.company?.name }}. Dated today or earlier it applies now; a later
        date is scheduled and today's record stays as it is until then.
      </p>
      <div class="grid">
        <div class="field">
          <label for="chg-effective">Effective date</label>
          <input id="chg-effective" v-model="form.effectiveDate" type="date" :min="target?.start_date" required />
        </div>
        <div class="field">
          <label for="chg-title">Job title</label>
          <input id="chg-title" v-model="form.jobTitle" maxlength="120" required />
        </div>
        <div class="field">
          <label for="chg-department">Department</label>
          <select id="chg-department" v-model="form.departmentId">
            <option value="">None</option>
            <option v-for="d in departments" :key="d.id" :value="d.id">{{ d.name }}</option>
          </select>
        </div>
        <div class="field">
          <label for="chg-location">Location</label>
          <select id="chg-location" v-model="form.locationId">
            <option value="">None</option>
            <option v-for="l in locations" :key="l.id" :value="l.id">{{ l.name }}</option>
          </select>
        </div>
        <div class="field">
          <label for="chg-manager">Manager</label>
          <select id="chg-manager" v-model="form.managerId">
            <option value="">None</option>
            <option v-for="p in people" :key="p.id" :value="p.id">{{ p.name }}</option>
          </select>
        </div>
        <div class="field">
          <label for="chg-type">Employment type</label>
          <select id="chg-type" v-model="form.employmentTypeKey">
            <option value="">Unchanged</option>
            <option v-for="t in employmentTypes" :key="t.key" :value="t.key">{{ t.label }}</option>
          </select>
        </div>
      </div>
      <div class="field">
        <label for="chg-reason">Reason (kept in the record's history)</label>
        <input id="chg-reason" v-model="form.reason" maxlength="500" placeholder="e.g. Promotion, transfer, restructure" />
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy">{{ busy ? 'Saving…' : 'Save change' }}</button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.change-dialog {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(560px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.change-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
