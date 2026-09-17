<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { formatAmount } from '@/lib/compensation'
import { ESTIMATE_NOTE, netEstimate, payrollSettingsInput, type PayrollSettingsForm } from '@/lib/payroll'
import type { Json } from '@/types/database'

/**
 * Settings → Payroll (plan 051): the tax percentage and the flat deduction
 * the net estimate uses when a period is prepared — the prototype's model,
 * kept until the real contribution rules are decided. The holding's
 * numbers stand in until the company writes its own. payroll.individual
 * here, or admin.
 */
const props = defineProps<{ companyId: string; companyName: string }>()

const auth = useAuthStore()
const form = ref<PayrollSettingsForm>({ tax_rate_percent: '', deductions_flat: '' })
const own = ref(false)
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const canEdit = computed(() => auth.isAdmin || auth.can(props.companyId, 'payroll.individual'))
const SAMPLE = 1000
const num = (n: number) => formatAmount(n, '').trim()
const preview = computed(() => {
  const parsed = payrollSettingsInput.safeParse(form.value)
  if (!parsed.success) return null
  return netEstimate({ amount: SAMPLE, bonus: 0, taxRatePercent: parsed.data.tax_rate_percent, deductionsFlat: parsed.data.deductions_flat })
})

async function load(): Promise<void> {
  loading.value = true
  const { data, error: err } = await supabase.rpc('payroll_settings', { p_company_id: props.companyId })
  loading.value = false
  if (err) {
    error.value = 'Could not load the payroll settings.'
    console.error('Payroll settings load failed:', err.message)
    return
  }
  const result = data as { tax_rate_percent: number; deductions_flat: number; own: boolean }
  form.value = { tax_rate_percent: String(result.tax_rate_percent ?? 0), deductions_flat: String(result.deductions_flat ?? 0) }
  own.value = result.own
}

async function save(): Promise<void> {
  const parsed = payrollSettingsInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the numbers.'
    return
  }
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err } = await supabase.rpc('set_payroll_settings', { p_company_id: props.companyId, p: parsed.data as unknown as Json })
  busy.value = false
  if (err) {
    error.value = err.code === '42501' ? err.message : 'Could not save the payroll settings.'
    console.error('Payroll settings save failed:', err.message)
    return
  }
  notice.value = 'Payroll settings saved; they apply to periods prepared from now on.'
  await load()
}

watch(() => props.companyId, load)
onMounted(load)
</script>

<template>
  <div class="card" data-testid="payroll-settings-panel">
    <div class="card-head">
      <div>
        <h2>Payroll estimate</h2>
        <p>{{ ESTIMATE_NOTE }} A prepared period applies these to each line: gross = amount + bonus, tax on the gross, the deduction once per person.</p>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <div v-if="loading" class="empty">Loading…</div>
    <form v-else class="body" novalidate @submit.prevent="save">
      <p class="source">{{ own ? `${companyName}'s own numbers.` : 'The holding default — save to make this company\'s own.' }}</p>
      <div class="grid">
        <div class="field"><label for="ps-rate">Tax rate (%)</label><input id="ps-rate" v-model="form.tax_rate_percent" inputmode="decimal" :disabled="!canEdit" /></div>
        <div class="field"><label for="ps-flat">Flat deduction per person</label><input id="ps-flat" v-model="form.deductions_flat" inputmode="decimal" :disabled="!canEdit" /></div>
      </div>
      <p v-if="preview" class="preview" data-testid="payroll-preview">
        On a {{ num(SAMPLE) }} line: tax {{ num(preview.tax) }}, net {{ num(preview.net) }}.
      </p>
      <div v-if="canEdit" class="actions"><button class="button" type="submit" :disabled="busy" data-testid="payroll-settings-save">{{ busy ? 'Saving…' : 'Save' }}</button></div>
    </form>
  </div>
</template>

<style scoped>
.in-card, .notice { margin: 12px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.body { padding: 14px 24px 18px; border-top: 1px solid #edf0eb; }
.source { margin: 0 0 12px; font-size: 11px; color: var(--muted); }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px 16px; }
.field { display: grid; gap: 4px; }
.field label { font-size: 11px; color: var(--muted); }
.field input { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
.preview { margin: 12px 0 0; font-size: 11px; color: var(--muted); }
.actions { display: flex; justify-content: flex-end; margin-top: 14px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
</style>
