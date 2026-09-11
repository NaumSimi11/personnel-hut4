<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { formatAmount } from '@/lib/compensation'

/**
 * Payroll tab (plan 023): annualised totals by currency for the company's
 * live employment, from compensation_summary (payroll.summary holders only —
 * the function refuses anyone else, so a failure here is shown, not hidden).
 */
const props = defineProps<{ companyId: string }>()

type Total = { currency: string; people: number; annualised: number }
type Summary = { totals: Total[]; covered: number; uncovered: number }

const loading = ref(true)
const error = ref<string | null>(null)
const summary = ref<Summary | null>(null)

function parseSummary(raw: unknown): Summary | null {
  if (!raw || typeof raw !== 'object') return null
  const obj = raw as Partial<Summary>
  const totals = Array.isArray(obj.totals)
    ? obj.totals.map((t) => ({ currency: String(t.currency), people: Number(t.people), annualised: Number(t.annualised) }))
    : []
  return { totals, covered: Number(obj.covered ?? 0), uncovered: Number(obj.uncovered ?? 0) }
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase.rpc('compensation_summary', { p_company_id: props.companyId })
  loading.value = false
  if (err) {
    error.value = /payroll\.summary/.test(err.message)
      ? 'Payroll totals need payroll.summary in this company.'
      : 'Could not load payroll totals.'
    console.error('Payroll summary failed:', err.message)
    return
  }
  summary.value = parseSummary(data)
}

onMounted(load)
watch(() => props.companyId, load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Payroll</h2>
        <p>Approved compensation in force today, annualised per currency.</p>
      </div>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <div v-else-if="error" class="error" role="alert">{{ error }}</div>
    <template v-else-if="summary">
      <div v-if="!summary.totals.length" class="empty">No approved compensation in force yet.</div>
      <div v-for="t in summary.totals" :key="t.currency" class="payroll-total">
        <div class="row-text">
          <strong>{{ formatAmount(t.annualised, t.currency) }} <span class="per-year">per year</span></strong>
          <small>{{ t.people }} {{ t.people === 1 ? 'person' : 'people' }} paid in {{ t.currency }}</small>
        </div>
      </div>
      <p class="payroll-coverage inline-note">
        {{ summary.covered }} with an approved record · {{ summary.uncovered }} without.
        Monthly ×12, daily ×260, hourly ×2080.
      </p>
    </template>
  </div>
</template>

<style scoped>
.payroll-total { padding: 15px 24px; border-top: 1px solid #edf0eb; }
.row-text strong { display: block; font-size: 15px; font-weight: 600; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.per-year { font-size: 11px; font-weight: 500; color: var(--muted); }
.payroll-coverage { margin: 0; padding: 14px 24px; border-top: 1px solid #edf0eb; font-size: 11px; color: var(--muted); }
.error { margin: 14px 24px; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
</style>
