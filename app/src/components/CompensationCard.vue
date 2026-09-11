<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import {
  STATUS_LABELS,
  compensationActions,
  currentRecord,
  formatAmount,
  proposalInput,
  recordLabel,
  todayDb,
  type CompensationAction,
} from '@/lib/compensation'

/**
 * Compensation for one person across their employment periods (plan 023).
 * The card decides only whether to attempt the load; RLS on
 * compensation_records (self or salary.view) is the real gate, and every
 * write goes through propose_compensation / decide_compensation, which
 * enforce salary.propose / salary.approve and proposer ≠ approver.
 */

type Period = {
  id: string
  company_id: string
  job_title: string
  status: string
  start_date: string
  company: { name: string } | null
}

type Record_ = {
  id: string
  employment_period_id: string
  amount: number
  currency: string
  pay_basis_key: string
  effective_date: string
  end_date: string | null
  status: string
  note: string | null
  proposed_by: string | null
  approved_by: string | null
  created_at: string
}

const props = withDefaults(defineProps<{ personId: string; periods: Period[]; title?: string }>(), {
  title: 'Compensation',
})

const auth = useAuthStore()
const visible = computed(
  () =>
    auth.isAdmin ||
    auth.personId === props.personId ||
    props.periods.some((p) => auth.can(p.company_id, 'salary.view')),
)

const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const records = ref<Record_[]>([])
const payBases = ref<{ key: string; label: string }[]>([])
const names = ref<Record<string, string>>({})
const proposingFor = ref<string | null>(null)
const form = ref({ amount: '', currency: '', payBasisKey: 'annual', effectiveDate: '', note: '' })

const basisLabel = (key: string) => payBases.value.find((b) => b.key === key)?.label.toLowerCase() ?? key
const personName = (id: string | null) => (id ? (names.value[id] ?? 'someone') : '—')

const livePeriods = computed(() =>
  [...props.periods].sort((a, b) => Number(a.status === 'former') - Number(b.status === 'former')),
)

function recordsFor(periodId: string): Record_[] {
  return records.value
    .filter((r) => r.employment_period_id === periodId)
    .sort((a, b) => b.effective_date.localeCompare(a.effective_date) || b.created_at.localeCompare(a.created_at))
}
const current = (periodId: string) => currentRecord(recordsFor(periodId), todayDb())
const pending = (periodId: string) => recordsFor(periodId).find((r) => r.status === 'proposed') ?? null
const history = (periodId: string) => recordsFor(periodId).filter((r) => r.status !== 'proposed')

function actionsFor(record: Record_, companyId: string): CompensationAction[] {
  return compensationActions(record, auth.personId, (cap) => auth.can(companyId, cap))
}
function canPropose(period: Period): boolean {
  return period.status !== 'former' && auth.can(period.company_id, 'salary.propose') && pending(period.id) === null
}

function describe(r: Record_): string {
  return `${formatAmount(Number(r.amount), r.currency)} ${basisLabel(r.pay_basis_key)}`
}

async function load(): Promise<void> {
  if (!visible.value || !props.periods.length) {
    loading.value = false
    return
  }
  loading.value = true
  error.value = null
  const [recRes, basisRes] = await Promise.all([
    supabase
      .from('compensation_records')
      .select('id, employment_period_id, amount, currency, pay_basis_key, effective_date, end_date, status, note, proposed_by, approved_by, created_at')
      .in('employment_period_id', props.periods.map((p) => p.id)),
    supabase.from('pay_bases').select('key, label').order('sort_order'),
  ])
  if (recRes.error || basisRes.error) {
    error.value = 'Could not load compensation.'
    console.error('Compensation load failed:', recRes.error?.message ?? basisRes.error?.message)
    loading.value = false
    return
  }
  records.value = (recRes.data ?? []) as Record_[]
  payBases.value = basisRes.data ?? []
  const ids = [...new Set(records.value.flatMap((r) => [r.proposed_by, r.approved_by]).filter((id): id is string => !!id))]
  if (ids.length) {
    const { data } = await supabase.from('people').select('id, full_name').in('id', ids)
    names.value = Object.fromEntries((data ?? []).map((p) => [p.id, p.full_name]))
  }
  loading.value = false
}

function startProposal(period: Period): void {
  const now = current(period.id)
  form.value = {
    amount: now ? String(now.amount) : '',
    currency: now?.currency ?? '',
    payBasisKey: now?.pay_basis_key ?? 'annual',
    effectiveDate: todayDb(),
    note: '',
  }
  error.value = null
  notice.value = null
  proposingFor.value = period.id
}

function friendly(message: string): string {
  if (/salary\.propose/.test(message)) return 'You need salary.propose in this company to propose a change.'
  if (/salary\.approve/.test(message)) return 'You need salary.approve in this company to decide on a proposal.'
  // Two proposals racing for the same period: the partial unique index wins.
  if (/compensation_one_open_proposal/.test(message)) return 'A proposal is already awaiting a decision for this employment.'
  return message
}

async function submitProposal(): Promise<void> {
  if (!proposingFor.value) return
  const parsed = proposalInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  error.value = null
  const { error: err } = await supabase.rpc('propose_compensation', {
    p_period_id: proposingFor.value,
    p_amount: parsed.data.amount,
    p_currency: parsed.data.currency,
    p_pay_basis_key: parsed.data.payBasisKey,
    p_effective_date: parsed.data.effectiveDate,
    p_note: parsed.data.note || undefined,
  })
  busy.value = false
  if (err) {
    error.value = friendly(err.message)
    console.error('Compensation proposal failed:', err.message)
    return
  }
  proposingFor.value = null
  notice.value = 'Proposal submitted — it takes effect once someone else approves it.'
  await load()
}

async function decide(record: Record_, decision: CompensationAction['to']): Promise<void> {
  if (decision === 'rejected' && !window.confirm('Reject this proposal?')) return
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err } = await supabase.rpc('decide_compensation', { p_record_id: record.id, p_decision: decision })
  busy.value = false
  if (err) {
    error.value = friendly(err.message)
    console.error('Compensation decision failed:', err.message)
    return
  }
  notice.value = decision === 'approved' ? 'Proposal approved.' : 'Proposal rejected.'
  await load()
}

onMounted(load)
watch(() => props.periods.map((p) => p.id).join(','), load)
</script>

<template>
  <div v-if="visible" class="card">
    <div class="card-head">
      <div>
        <h2>{{ title }}</h2>
        <p>Changes are proposed by one person and approved by another; history is never overwritten.</p>
      </div>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="notice" class="notice" role="status">{{ notice }}</div>
      <div v-if="error" class="error" role="alert">{{ error }}</div>
      <div v-if="!periods.length" class="empty">No employment recorded, so no compensation yet.</div>

      <div v-for="period in livePeriods" :key="period.id" class="period">
        <div v-if="periods.length > 1" class="period-title">{{ period.job_title }} · {{ period.company?.name }}</div>

        <div class="comp-current">
          <template v-if="current(period.id)">
            <strong>{{ describe(current(period.id)!) }}</strong>
            <small>since {{ current(period.id)!.effective_date }}</small>
          </template>
          <template v-else>
            <strong>No approved compensation</strong>
            <small>{{ period.status === 'former' ? 'Employment has ended.' : 'Propose an amount to record one.' }}</small>
          </template>
        </div>

        <div v-if="pending(period.id)" class="comp-pending">
          <div class="row-text">
            <strong>{{ describe(pending(period.id)!) }} from {{ pending(period.id)!.effective_date }}</strong>
            <small>
              {{ STATUS_LABELS.proposed }} · proposed by {{ personName(pending(period.id)!.proposed_by) }}
              <template v-if="pending(period.id)!.note"> · {{ pending(period.id)!.note }}</template>
            </small>
          </div>
          <div class="actions">
            <button
              v-for="action in actionsFor(pending(period.id)!, period.company_id)"
              :key="action.to"
              class="button small-btn"
              :class="{ secondary: action.to === 'rejected' }"
              :disabled="busy"
              @click="decide(pending(period.id)!, action.to)"
            >
              {{ action.label }}
            </button>
          </div>
        </div>

        <form v-if="proposingFor === period.id" class="propose" novalidate @submit.prevent="submitProposal">
          <label>
            <span>Amount</span>
            <input id="comp-amount" v-model="form.amount" type="number" min="0" step="0.01" inputmode="decimal" />
          </label>
          <label>
            <span>Currency</span>
            <input id="comp-currency" v-model="form.currency" maxlength="3" placeholder="EUR" autocapitalize="characters" />
          </label>
          <label>
            <span>Pay basis</span>
            <select id="comp-basis" v-model="form.payBasisKey">
              <option v-for="b in payBases" :key="b.key" :value="b.key">{{ b.label }}</option>
            </select>
          </label>
          <label>
            <span>Effective from</span>
            <input id="comp-effective" v-model="form.effectiveDate" type="date" />
          </label>
          <label class="wide">
            <span>Note</span>
            <input id="comp-note" v-model="form.note" placeholder="Why this change (optional)" />
          </label>
          <div class="form-actions">
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="proposingFor = null">Cancel</button>
            <button type="submit" class="button small-btn" :disabled="busy">Submit proposal</button>
          </div>
        </form>
        <div v-else-if="canPropose(period)" class="propose-cta">
          <button class="button secondary small-btn" @click="startProposal(period)">Propose change</button>
        </div>

        <div v-if="history(period.id).length > 1 || (history(period.id).length === 1 && !current(period.id))" class="comp-history">
          <div class="history-title">History</div>
          <div v-for="r in history(period.id)" :key="r.id" class="comp-history-row">
            <div class="row-text">
              <strong>{{ describe(r) }}</strong>
              <small>
                {{ r.effective_date }} → {{ r.end_date ?? (r.status === 'approved' ? 'present' : '—') }}
                <template v-if="r.approved_by"> · {{ r.status === 'rejected' ? 'rejected' : 'approved' }} by {{ personName(r.approved_by) }}</template>
                <template v-if="r.note"> · {{ r.note }}</template>
              </small>
            </div>
            <span class="badge" :class="recordLabel(r).toLowerCase()">{{ recordLabel(r) }}</span>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.period { border-top: 1px solid #edf0eb; }
.period-title { padding: 12px 24px 0; font-size: 11px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }
.comp-current { padding: 15px 24px; }
.comp-current strong { display: block; font-size: 15px; font-weight: 600; }
.comp-current small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.comp-pending { display: flex; align-items: center; gap: 13px; padding: 13px 24px; background: #fbf7ea; border-top: 1px solid #f1e8c8; }
.row-text { flex: 1; min-width: 0; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.actions { display: flex; gap: 8px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.propose { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 14px; padding: 16px 24px; background: #fafbf8; border-top: 1px solid var(--line); }
.propose label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.propose label.wide, .propose .form-actions { grid-column: 1 / -1; }
.propose input, .propose select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
.form-actions { display: flex; justify-content: flex-end; gap: 8px; }
.propose-cta { padding: 0 24px 16px; }
.comp-history { border-top: 1px solid #edf0eb; }
.history-title { padding: 12px 24px 4px; font-size: 10px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }
.comp-history-row { display: flex; align-items: center; gap: 13px; padding: 10px 24px; }
.badge.superseded, .badge.rejected { background: #f1f1ee; color: var(--muted); }
.badge.current { background: #edf5ed; color: #3e744e; }
.badge.scheduled { background: #eef3fb; color: #3b5a8a; }
.badge.approved { background: #edf5ed; color: #3e744e; }
.notice { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
@media (max-width: 560px) { .propose { grid-template-columns: 1fr; } }
</style>
