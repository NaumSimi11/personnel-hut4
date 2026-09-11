<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { z } from 'zod'
import { supabase } from '@/lib/supabase'

/**
 * Create an employee record with its first employment period. Deliberately
 * separate from inviting: an employee record is not an account (blueprint §2);
 * access comes later via invite + grants.
 */
const emit = defineEmits<{ created: [personId: string] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const companies = ref<{ id: string; name: string }[]>([])
const employmentTypes = ref<{ key: string; label: string }[]>([])
const form = ref({
  fullName: '',
  workEmail: '',
  companyId: '',
  jobTitle: '',
  employmentType: 'full_time',
  startDate: new Date().toISOString().slice(0, 10),
})
const error = ref<string | null>(null)
const busy = ref(false)

const input = z.object({
  fullName: z.string().trim().min(2, 'Enter the full name.').max(120),
  workEmail: z.union([z.literal(''), z.string().trim().toLowerCase().email('Enter a valid email or leave it empty.')]),
  companyId: z.string().uuid('Choose a company.'),
  jobTitle: z.string().trim().min(2, 'Enter a job title.').max(120),
  employmentType: z.string().min(1),
  startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a start date.'),
})

function open(): void {
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

async function submit(): Promise<void> {
  error.value = null
  const parsed = input.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  try {
    const { data: person, error: personErr } = await supabase
      .from('people')
      .insert({
        full_name: parsed.data.fullName,
        work_email: parsed.data.workEmail || null,
      })
      .select('id')
      .single()
    if (personErr) throw new Error(personErr.message)

    const status = parsed.data.startDate > new Date().toISOString().slice(0, 10) ? 'pre_start' : 'active'
    const { error: empErr } = await supabase.from('employment_periods').insert({
      person_id: person.id,
      company_id: parsed.data.companyId,
      job_title: parsed.data.jobTitle,
      employment_type_key: parsed.data.employmentType,
      status,
      start_date: parsed.data.startDate,
    })
    if (empErr) throw new Error(friendly(empErr.message))

    form.value = { ...form.value, fullName: '', workEmail: '', jobTitle: '' }
    dialog.value?.close()
    emit('created', person.id)
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not create the employee.'
  } finally {
    busy.value = false
  }
}

function friendly(message: string): string {
  if (/no_overlapping_employment/.test(message))
    return 'This person already has an employment period covering that date.'
  return message
}

onMounted(async () => {
  const [companiesRes, typesRes] = await Promise.all([
    supabase.from('companies').select('id, name').eq('kind', 'company').order('name'),
    supabase.from('employment_types').select('key, label').is('archived_at', null).order('sort_order'),
  ])
  companies.value = companiesRes.data ?? []
  employmentTypes.value = typesRes.data ?? []
  if (!form.value.companyId && companies.value[0]) form.value.companyId = companies.value[0].id
})
</script>

<template>
  <dialog ref="dialog" class="add-person" aria-labelledby="add-person-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Employee records</div>
      <h2 id="add-person-title">Add a person.</h2>
      <p class="hint">
        This creates the employment record only — no login. Send an invitation separately when they
        should have access.
      </p>
      <div class="field">
        <label for="ap-name">Full name</label>
        <input id="ap-name" v-model="form.fullName" required maxlength="120" />
      </div>
      <div class="field">
        <label for="ap-email">Work email (optional)</label>
        <input id="ap-email" v-model="form.workEmail" type="email" maxlength="320" />
      </div>
      <div class="grid">
        <div class="field">
          <label for="ap-company">Employing company</label>
          <select id="ap-company" v-model="form.companyId">
            <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
          </select>
        </div>
        <div class="field">
          <label for="ap-title">Job title</label>
          <input id="ap-title" v-model="form.jobTitle" required maxlength="120" />
        </div>
        <div class="field">
          <label for="ap-type">Employment type</label>
          <select id="ap-type" v-model="form.employmentType">
            <option v-for="t in employmentTypes" :key="t.key" :value="t.key">{{ t.label }}</option>
          </select>
        </div>
        <div class="field">
          <label for="ap-start">Start date</label>
          <input id="ap-start" v-model="form.startDate" type="date" required />
        </div>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy">
          {{ busy ? 'Creating…' : 'Create employee' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.add-person {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(480px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.add-person::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
