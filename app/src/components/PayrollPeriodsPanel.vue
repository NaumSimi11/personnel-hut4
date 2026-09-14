<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { formatAmount, todayDb } from '@/lib/compensation'
import {
  defaultPeriod,
  payrollActions,
  payrollCsv,
  payrollFileName,
  periodInput,
  periodStatusLabel,
  type PayrollAction,
  type PayrollLine,
} from '@/lib/payroll'

/**
 * Payroll periods for one company (plan 031): prepare a snapshot of the
 * compensation in force, review its lines, approve (someone other than
 * the preparer), download the CSV and mark it exported. Reading needs
 * payroll.summary (periods) and payroll.individual (lines); every state
 * change goes through the functions of migration 0023.
 */

const props = defineProps<{ companyId: string; companyCode: string }>()

type Period = {
  id: string
  period_start: string
  period_end: string
  currency: string
  status: string
  prepared_by: string | null
  prepared_at: string | null
  approved_by: string | null
  exported_at: string | null
  note: string | null
}
type Line = PayrollLine & { id: string; person_id: string }

const auth = useAuthStore()
const can = (cap: string) => auth.can(props.companyId, cap)
const canPrepare = computed(() => can('payroll.individual'))

const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const periods = ref<Period[]>([])
const names = ref<Record<string, string>>({})
const openId = ref<string | null>(null)
const lines = ref<Line[]>([])
const linesLoading = ref(false)
const adding = ref(false)
const form = ref({ start: '', end: '', currency: 'EUR', note: '' })

const personName = (id: string | null) => (id ? (names.value[id] ?? 'someone') : '—')
const actionsFor = (p: Period): PayrollAction[] => payrollActions(p, auth.personId, can)
const openPeriod = computed(() => periods.value.find((p) => p.id === openId.value) ?? null)
const total = computed(() => lines.value.reduce((sum, l) => sum + Number(l.amount), 0))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('payroll_periods')
    .select('id, period_start, period_end, currency, status, prepared_by, prepared_at, approved_by, exported_at, note')
    .eq('company_id', props.companyId)
    .order('period_start', { ascending: false })
  loading.value = false
  if (err) {
    error.value = 'Could not load payroll periods.'
    console.error('Payroll periods load failed:', err.message)
    return
  }
  periods.value = (data ?? []) as Period[]
  const ids = [...new Set(periods.value.flatMap((p) => [p.prepared_by, p.approved_by]).filter((id): id is string => !!id))]
  if (ids.length) {
    const { data: people, error: peopleErr } = await supabase.from('people').select('id, full_name').in('id', ids)
    if (peopleErr) console.error('Payroll actor lookup failed:', peopleErr.message)
    names.value = Object.fromEntries((people ?? []).map((p) => [p.id, p.full_name]))
  }
  if (openId.value) await loadLines(openId.value)
}

async function loadLines(periodId: string): Promise<void> {
  linesLoading.value = true
  const { data, error: err } = await supabase
    .from('payroll_lines')
    .select('id, person_id, full_name, job_title, amount, currency, pay_basis_key, effective_from, effective_to, days_covered')
    .eq('period_id', periodId)
    .order('full_name')
    .order('effective_from')
  linesLoading.value = false
  if (err) {
    error.value = 'Could not load the lines (payroll.individual is needed).'
    console.error('Payroll lines load failed:', err.message)
    lines.value = []
    return
  }
  lines.value = (data ?? []) as Line[]
}

async function toggleLines(p: Period): Promise<void> {
  if (openId.value === p.id) {
    openId.value = null
    lines.value = []
    return
  }
  openId.value = p.id
  await loadLines(p.id)
}

function startPrepare(): void {
  const month = defaultPeriod(todayDb())
  form.value = { start: month.start, end: month.end, currency: periods.value[0]?.currency ?? 'EUR', note: '' }
  error.value = null
  notice.value = null
  adding.value = true
}

function friendly(message: string): string {
  if (/payroll\.individual/.test(message)) return 'You need payroll.individual in this company to prepare payroll.'
  if (/payroll\.approve/.test(message)) return 'You need payroll.approve in this company.'
  if (/payroll\.export/.test(message)) return 'You need payroll.export in this company.'
  if (/cannot approve it/.test(message)) return 'The person who prepared a period cannot approve it.'
  return message
}

async function prepare(start: string, end: string, currency: string, note: string): Promise<boolean> {
  busy.value = true
  error.value = null
  notice.value = null
  const { data, error: err } = await supabase.rpc('prepare_payroll_period', {
    p_company_id: props.companyId,
    p_start: start,
    p_end: end,
    p_currency: currency,
    p_note: note || undefined,
  })
  busy.value = false
  if (err) {
    error.value = friendly(err.message)
    console.error('Payroll prepare failed:', err.message)
    return false
  }
  const result = data as { lines: number; uncovered: number } | null
  notice.value = `Prepared: ${result?.lines ?? 0} lines${result?.uncovered ? ` · ${result.uncovered} active ${result.uncovered === 1 ? 'person has' : 'people have'} no approved record in ${currency}` : ''}.`
  await load()
  return true
}

async function submitPrepare(): Promise<void> {
  const parsed = periodInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  const ok = await prepare(parsed.data.start, parsed.data.end, parsed.data.currency, parsed.data.note)
  if (ok) adding.value = false
}

async function act(p: Period, action: PayrollAction): Promise<void> {
  if (action.key === 'reprepare') {
    if (!window.confirm('Prepare this period again from the current records? Its lines are rebuilt.')) return
    await prepare(p.period_start, p.period_end, p.currency, '')
    return
  }
  const fn = action.key === 'approve' ? 'approve_payroll_period' : action.key === 'export' ? 'mark_payroll_exported' : 'reopen_payroll_period'
  if (action.key === 'export' && !window.confirm('Mark this period as exported? It is then closed.')) return
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err } = await supabase.rpc(fn, { p_period_id: p.id })
  busy.value = false
  if (err) {
    error.value = friendly(err.message)
    console.error(`Payroll ${action.key} failed:`, err.message)
    return
  }
  await load()
}

async function download(p: Period): Promise<void> {
  error.value = null
  const { data, error: err } = await supabase
    .from('payroll_lines')
    .select('full_name, job_title, amount, currency, pay_basis_key, effective_from, effective_to, days_covered')
    .eq('period_id', p.id)
    .order('full_name')
    .order('effective_from')
  if (err) {
    error.value = 'Could not load the lines for the export.'
    console.error('Payroll export failed:', err.message)
    return
  }
  const blob = new Blob([payrollCsv(p, (data ?? []) as PayrollLine[])], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = payrollFileName(p, props.companyCode)
  a.click()
  URL.revokeObjectURL(url)
}

onMounted(load)
watch(() => props.companyId, load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Payroll periods</h2>
        <p>A period snapshots what was in force day by day. Someone else approves; the export goes to the accountant.</p>
      </div>
      <button v-if="canPrepare && !adding" class="button small-btn" type="button" @click="startPrepare">Prepare a period</button>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="notice" class="notice" role="status">{{ notice }}</div>
      <div v-if="error" class="error" role="alert">{{ error }}</div>

      <form v-if="adding" class="form" novalidate @submit.prevent="submitPrepare">
        <label><span>From</span><input id="pp-start" v-model="form.start" type="date" /></label>
        <label><span>To</span><input id="pp-end" v-model="form.end" type="date" /></label>
        <label><span>Currency</span><input id="pp-currency" v-model="form.currency" maxlength="3" autocapitalize="characters" /></label>
        <label><span>Note</span><input id="pp-note" v-model="form.note" placeholder="Optional" /></label>
        <div class="form-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="adding = false">Cancel</button>
          <button type="submit" class="button small-btn" :disabled="busy">{{ busy ? 'Preparing…' : 'Prepare' }}</button>
        </div>
      </form>

      <div v-if="!periods.length" class="empty">No payroll periods yet.</div>
      <template v-for="p in periods" :key="p.id">
        <div class="period-row" :class="p.status">
          <div class="row-text">
            <strong>{{ p.period_start }} → {{ p.period_end }} <span class="muted">· {{ p.currency }}</span></strong>
            <small>
              {{ periodStatusLabel(p.status) }}
              <template v-if="p.prepared_by"> · prepared by {{ personName(p.prepared_by) }}</template>
              <template v-if="p.approved_by"> · approved by {{ personName(p.approved_by) }}</template>
              <template v-if="p.exported_at"> · exported {{ p.exported_at.slice(0, 10) }}</template>
              <template v-if="p.note"> · {{ p.note }}</template>
            </small>
          </div>
          <div class="actions">
            <button v-if="can('payroll.individual')" class="button secondary small-btn" type="button" @click="toggleLines(p)">
              {{ openId === p.id ? 'Hide lines' : 'Lines' }}
            </button>
            <button v-if="can('payroll.individual') && p.status !== 'draft'" class="button secondary small-btn" type="button" @click="download(p)">
              Download CSV
            </button>
            <button
              v-for="action in actionsFor(p)"
              :key="action.key"
              class="button small-btn"
              :class="{ secondary: action.key !== 'approve' }"
              type="button"
              :disabled="busy"
              @click="act(p, action)"
            >
              {{ action.label }}
            </button>
          </div>
        </div>
        <div v-if="openId === p.id" class="lines">
          <div v-if="linesLoading" class="empty">Loading lines…</div>
          <div v-else-if="!lines.length" class="empty">No lines: nobody has an approved record in {{ p.currency }} for this range.</div>
          <template v-else>
            <div v-for="l in lines" :key="l.id" class="line-row">
              <div class="row-text">
                <strong>{{ l.full_name }} <span class="muted">· {{ l.job_title }}</span></strong>
                <small>{{ formatAmount(Number(l.amount), l.currency) }} {{ l.pay_basis_key }} · {{ l.effective_from }} → {{ l.effective_to }} · {{ l.days_covered }} days</small>
              </div>
            </div>
            <div class="lines-total">{{ lines.length }} lines · amounts as recorded, sum {{ formatAmount(total, openPeriod?.currency ?? '') }} (not pro-rated)</div>
          </template>
        </div>
      </template>
    </template>
  </div>
</template>

<style scoped>
.period-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.period-row.exported { opacity: 0.75; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.muted { font-weight: 400; color: var(--muted); }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.lines { background: #fafbf8; border-top: 1px solid #edf0eb; }
.line-row { padding: 9px 24px 9px 40px; border-top: 1px solid #f1f3ee; }
.lines-total { padding: 10px 24px 12px 40px; font-size: 11px; color: var(--muted); }
.form { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 14px; padding: 16px 24px; background: #fafbf8; border-top: 1px solid var(--line); }
.form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.form .form-actions { grid-column: 1 / -1; display: flex; justify-content: flex-end; gap: 8px; }
.form input { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
.notice { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
@media (max-width: 560px) { .form { grid-template-columns: 1fr; } }
</style>
