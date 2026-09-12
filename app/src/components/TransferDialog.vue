<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { transferInput, friendlyTransferError } from '@/lib/transfer'

/**
 * Move a person to another company as one act (plan 035a): the current
 * period ends the day before, a new one starts on the date at the target —
 * same title and type unless changed. Dated today or earlier it applies
 * now; later it waits and the nightly job completes it. The database
 * (transfer_employment) needs employment.edit in both companies.
 */

export type TransferTarget = {
  id: string
  company_id: string
  person_id: string
  job_title: string
  employment_type_key: string | null
  start_date: string
  end_date: string | null
  company: { name: string } | null
}

const emit = defineEmits<{ transferred: [result: { applied: boolean; effectiveDate: string; companyName: string }] }>()

const auth = useAuthStore()
const dialog = ref<HTMLDialogElement | null>(null)
const target = ref<TransferTarget | null>(null)
const personName = ref('')
const companies = ref<{ id: string; name: string }[]>([])
const employmentTypes = ref<{ key: string; label: string }[]>([])
const form = ref({ companyId: '', effectiveDate: '', jobTitle: '', employmentTypeKey: '', reason: '' })
const error = ref<string | null>(null)
const busy = ref(false)

// Only where the viewer may edit employment, and never the company they are leaving.
const targets = computed(() =>
  companies.value.filter((c) => c.id !== target.value?.company_id && auth.can(c.id, 'employment.edit')),
)

async function open(period: TransferTarget, name: string): Promise<void> {
  target.value = period
  personName.value = name
  error.value = null
  // Default to today, or the day after the start when the employment began today.
  const minDate = minDateFor(period) ?? todayDb()
  form.value = {
    companyId: '',
    effectiveDate: todayDb() > minDate ? todayDb() : minDate,
    jobTitle: period.job_title,
    employmentTypeKey: period.employment_type_key ?? '',
    reason: '',
  }
  dialog.value?.showModal()
  const [companiesRes, typesRes] = await Promise.all([
    supabase.from('companies').select('id, name').is('archived_at', null).order('name'),
    supabase.from('employment_types').select('key, label').is('archived_at', null).order('sort_order'),
  ])
  companies.value = companiesRes.data ?? []
  employmentTypes.value = typesRes.data ?? []
  form.value = { ...form.value, companyId: targets.value[0]?.id ?? '' }
}
defineExpose({ open })

/** The earliest transfer date: the day after the employment started (the old period keeps a day). */
function minDateFor(period: TransferTarget | null): string | undefined {
  if (!period) return undefined
  const d = new Date(`${period.start_date}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + 1)
  return d.toISOString().slice(0, 10)
}

async function submit(): Promise<void> {
  if (!target.value) return
  error.value = null
  const parsed = transferInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  // Same rule as transfer_employment: the old period must keep at least one day.
  if (parsed.data.effectiveDate <= target.value.start_date) {
    error.value = `The transfer date must be after the employment started (${target.value.start_date}).`
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('transfer_employment', {
    p_period_id: target.value.id,
    p_company_id: parsed.data.companyId,
    p_effective_date: parsed.data.effectiveDate,
    p_job_title: parsed.data.jobTitle || undefined,
    p_employment_type_key: parsed.data.employmentTypeKey || undefined,
    p_reason: parsed.data.reason || undefined,
  })
  busy.value = false
  if (err) {
    error.value = friendlyTransferError(err.message)
    console.error('Transfer failed:', err.message)
    return
  }
  dialog.value?.close()
  emit('transferred', {
    applied: (data as { applied: boolean })?.applied === true,
    effectiveDate: parsed.data.effectiveDate,
    companyName: companies.value.find((c) => c.id === parsed.data.companyId)?.name ?? '',
  })
}
</script>

<template>
  <dialog ref="dialog" class="transfer-dialog" aria-labelledby="transfer-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Transfer</div>
      <h2 id="transfer-title">Move {{ personName || 'this person' }} to another company.</h2>
      <p class="hint">
        {{ target?.job_title }} · {{ target?.company?.name }} ends the day before; the new employment starts on the
        date. History stays: nothing is overwritten, and it is not a departure — no offboarding plan.
      </p>
      <div class="grid">
        <div class="field">
          <label for="tr-company">To</label>
          <select id="tr-company" v-model="form.companyId">
            <option v-for="c in targets" :key="c.id" :value="c.id">{{ c.name }}</option>
          </select>
        </div>
        <div class="field">
          <label for="tr-date">From</label>
          <input id="tr-date" v-model="form.effectiveDate" type="date" :min="minDateFor(target)" required />
        </div>
        <div class="field">
          <label for="tr-title">Job title there</label>
          <input id="tr-title" v-model="form.jobTitle" maxlength="120" />
        </div>
        <div class="field">
          <label for="tr-type">Employment type</label>
          <select id="tr-type" v-model="form.employmentTypeKey">
            <option value="">Unchanged</option>
            <option v-for="t in employmentTypes" :key="t.key" :value="t.key">{{ t.label }}</option>
          </select>
        </div>
      </div>
      <div class="field">
        <label for="tr-reason">Reason (kept in the record's history)</label>
        <input id="tr-reason" v-model="form.reason" maxlength="500" placeholder="e.g. Finance function moves to the holding" />
      </div>
      <p v-if="!targets.length" class="error-note" role="alert">You need employment.edit in another company to transfer someone there.</p>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy || !targets.length">{{ busy ? 'Moving…' : 'Transfer' }}</button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.transfer-dialog { border: 0; border-radius: 15px; padding: 0; width: min(560px, calc(100vw - 36px)); box-shadow: 0 25px 100px #122f3038; color: var(--ink); }
.transfer-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
