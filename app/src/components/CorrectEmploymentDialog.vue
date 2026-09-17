<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { EMPTY_STRUCTURE, loadCompanyStructure, type Structure } from '@/lib/companyStructure'
import {
  correctionInput,
  fieldsFor,
  formFor,
  localProblem,
  messageFor,
  unchanged,
  type CorrectionForm,
} from '@/lib/employmentCorrection'

/**
 * Correct an employment period (migrations 0037, 0038): the record is wrong,
 * rather than the facts having changed on a date. Transfers, departures and
 * dated changes have their own dialogs; this one only fixes what the period
 * says about itself — start date, title, type, department, location,
 * manager — and keeps the old picture with a reason.
 */

export type CorrectTarget = {
  id: string
  company_id: string
  person_id: string
  start_date: string
  end_date: string | null
  job_title: string
  employment_type_key: string | null
  department_id: string | null
  location_id: string | null
  manager_id: string | null
  status: string
  company: { name: string } | null
}

type Option = { id: string; name: string }

/** The pickers' options come from the page, which already holds them for the facts strip. */
const props = defineProps<{ employmentTypes: { key: string; label: string }[]; people: Option[] }>()
const emit = defineEmits<{ corrected: [result: { startDate: string; jobTitle: string }] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const target = ref<CorrectTarget | null>(null)
const personName = ref('')
const form = ref<CorrectionForm>(formFor({ start_date: '', job_title: '', employment_type_key: null, end_date: null, department_id: null, location_id: null, manager_id: null }))
const structure = ref<Structure>(EMPTY_STRUCTURE)
const error = ref<string | null>(null)
const busy = ref(false)

const managers = computed(() => props.people.filter((p) => p.id !== target.value?.person_id))

async function open(period: CorrectTarget, name: string): Promise<void> {
  target.value = period
  personName.value = name
  form.value = formFor(period)
  error.value = null
  dialog.value?.showModal()
  try {
    structure.value = await loadCompanyStructure(period.company_id)
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not load departments and locations.'
  }
}
defineExpose({ open })

async function submit(): Promise<void> {
  const period = target.value
  if (!period) return
  error.value = null
  const parsed = correctionInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  if (unchanged(period, parsed.data)) {
    error.value = 'Nothing has changed.'
    return
  }
  const problem = localProblem(period, parsed.data)
  if (problem) {
    error.value = problem
    return
  }
  busy.value = true
  const { error: err } = await supabase.rpc('correct_employment', {
    p_period_id: period.id,
    p_start_date: parsed.data.startDate,
    p_job_title: parsed.data.jobTitle,
    p_employment_type_key: parsed.data.employmentTypeKey || undefined,
    p_reason: parsed.data.reason || undefined,
    p_fields: fieldsFor(period, parsed.data),
  })
  busy.value = false
  if (err) {
    error.value = messageFor(err)
    return
  }
  dialog.value?.close()
  emit('corrected', { startDate: parsed.data.startDate, jobTitle: parsed.data.jobTitle })
}
</script>

<template>
  <dialog ref="dialog" class="correct-dialog" aria-labelledby="correct-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Correction</div>
      <h2 id="correct-title">Correct {{ personName || 'this' }}'s employment record.</h2>
      <p class="hint">
        {{ target?.job_title }} · {{ target?.company?.name }}. Use this when the record itself is
        wrong — a start date or a department that was never right. For something that changed on a
        date use Schedule change, and for a move between companies use Transfer.
      </p>
      <div class="grid">
        <div class="field">
          <label for="cor-start">Start date</label>
          <input
            id="cor-start"
            v-model="form.startDate"
            type="date"
            required
            :max="target?.end_date ?? undefined"
          />
        </div>
        <div class="field">
          <label for="cor-title">Job title</label>
          <input id="cor-title" v-model="form.jobTitle" maxlength="120" required />
        </div>
        <div class="field">
          <label for="cor-type">Employment type</label>
          <select id="cor-type" v-model="form.employmentTypeKey">
            <option value="">Not recorded</option>
            <option v-for="t in props.employmentTypes" :key="t.key" :value="t.key">{{ t.label }}</option>
          </select>
        </div>
        <div class="field">
          <label for="cor-department">Department</label>
          <select id="cor-department" v-model="form.departmentId">
            <option value="">Not set</option>
            <option v-for="d in structure.departments" :key="d.id" :value="d.id">{{ d.name }}</option>
          </select>
        </div>
        <div class="field">
          <label for="cor-location">Location</label>
          <select id="cor-location" v-model="form.locationId">
            <option value="">Not set</option>
            <option v-for="l in structure.locations" :key="l.id" :value="l.id">{{ l.name }}</option>
          </select>
        </div>
        <div class="field">
          <label for="cor-manager">Manager</label>
          <select id="cor-manager" v-model="form.managerId">
            <option value="">No manager</option>
            <option v-for="p in managers" :key="p.id" :value="p.id">{{ p.name }}</option>
          </select>
        </div>
      </div>
      <div class="field">
        <label for="cor-reason">Reason</label>
        <input
          id="cor-reason"
          v-model="form.reason"
          maxlength="500"
          placeholder="e.g. Contract says 1 November 2024"
        />
        <small class="field-hint">Kept with the old and new values, so the record shows why it moved.</small>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy">
          {{ busy ? 'Saving…' : 'Save correction' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.correct-dialog {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(600px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.correct-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
