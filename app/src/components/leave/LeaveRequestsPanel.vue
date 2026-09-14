<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { cancellationState, shortDate } from '@/lib/leave'
import LeaveRequestsList, { type LeaveRequestRow } from '@/components/LeaveRequestsList.vue'
import CorrectLeaveDialog, { type CorrectionTarget } from '@/components/leave/CorrectLeaveDialog.vue'

/**
 * The manager desk (plan 036, laid out after the old HR's in plan 041):
 * what waits on a decision, asks to cancel, then the settled record —
 * approved and cancelled — as a table you search, not a list you scroll
 * past. Approved leave can be corrected (dates, kinds) and the balance
 * follows. RLS limits rows to companies where the viewer holds leave.view
 * or leave.approve; actions show only where leave.approve applies.
 */

type Tab = 'decide' | 'asks' | 'approved' | 'cancelled'
type Row = LeaveRequestRow & {
  created_at: string
  decided_at: string | null
  cancelled_at: string | null
  decider?: { full_name: string } | null
  canceller?: { full_name: string } | null
  corrections?: Correction[]
}
type Correction = {
  id: string
  old_start: string
  old_end: string
  old_leave_type_key: string
  old_working_days: number
  new_start: string
  new_end: string
  new_leave_type_key: string
  new_working_days: number
  split_request_ids: string[]
  note: string | null
  corrected_at: string
  corrector?: { full_name: string } | null
}

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']

const props = defineProps<{ companyIds: string[]; companies: { id: string; name: string; country_code: string | null }[] }>()

const auth = useAuthStore()
const requests = ref<Row[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const tab = ref<Tab>('decide')
const query = ref('')
const month = ref('all')
const company = ref('all')
const correctDialog = ref<InstanceType<typeof CorrectLeaveDialog> | null>(null)

const decide = computed(() => requests.value.filter((r) => r.status === 'pending'))
const asks = computed(() => requests.value.filter((r) => cancellationState(r) === 'open'))
const approved = computed(() => requests.value.filter((r) => r.status === 'approved'))
const cancelled = computed(() => requests.value.filter((r) => r.status === 'cancelled' || r.status === 'rejected'))
const tabs = computed(() => [
  { id: 'decide' as Tab, label: 'To decide', count: decide.value.length, urgent: true },
  { id: 'asks' as Tab, label: 'Asks to cancel', count: asks.value.length, urgent: true },
  { id: 'approved' as Tab, label: 'Approved', count: approved.value.length, urgent: false },
  { id: 'cancelled' as Tab, label: 'Cancelled / rejected', count: cancelled.value.length, urgent: false },
])
const source = computed(() => ({ decide: decide.value, asks: asks.value, approved: approved.value, cancelled: cancelled.value })[tab.value])

/** `YYYY-MM` keys the record touches, so a filter matches leave spanning a month boundary. */
function monthsCovered(start: string, end: string): string[] {
  const keys: string[] = []
  let y = Number(start.slice(0, 4))
  let m = Number(start.slice(5, 7))
  const ey = Number(end.slice(0, 4))
  const em = Number(end.slice(5, 7))
  while ((y < ey || (y === ey && m <= em)) && keys.length < 36) {
    keys.push(`${y}-${String(m).padStart(2, '0')}`)
    m += 1
    if (m > 12) {
      m = 1
      y += 1
    }
  }
  return keys
}
const monthOptions = computed(() => {
  const keys = new Set<string>()
  for (const r of source.value) for (const k of monthsCovered(r.start_date, r.end_date)) keys.add(k)
  return [...keys].sort().reverse()
})
const fold = (s: string) => s.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase()
const shown = computed(() => {
  const words = fold(query.value).split(/\s+/).filter(Boolean)
  return source.value
    .filter((r) => {
      if (month.value !== 'all' && !monthsCovered(r.start_date, r.end_date).includes(month.value)) return false
      if (company.value !== 'all' && r.company_id !== company.value) return false
      if (!words.length) return true
      const hay = fold(`${r.person?.full_name ?? ''} ${r.company?.name ?? ''} ${r.leave_type?.label ?? r.leave_type_key}`)
      return words.every((w) => hay.includes(w))
    })
    .sort((a, b) => b.start_date.localeCompare(a.start_date))
})
const filtered = computed(() => query.value !== '' || month.value !== 'all' || company.value !== 'all')

function canCorrect(r: Row): boolean {
  return r.status === 'approved' && auth.can(r.company_id, 'leave.approve') && (auth.isAdmin || r.person_id !== auth.personId)
}
function byWhom(r: Row): { name: string; at: string } | null {
  if (tab.value === 'cancelled') return r.cancelled_at ? { name: r.canceller?.full_name ?? 'no author recorded', at: r.cancelled_at } : null
  return r.decided_at ? { name: r.decider?.full_name ?? 'no author recorded', at: r.decided_at } : null
}
function stamp(iso: string): string {
  return new Date(iso).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })
}
function describe(c: Correction): string {
  const was = `${shortDate(c.old_start)} → ${shortDate(c.old_end)} · ${c.old_working_days} ${c.old_leave_type_key.replace('_', ' ')}`
  const now = `${shortDate(c.new_start)} → ${shortDate(c.new_end)} · ${c.new_working_days} ${c.new_leave_type_key.replace('_', ' ')}`
  const split = c.split_request_ids.length ? ` (+${c.split_request_ids.length} split off)` : ''
  return `${was}  ⟶  ${now}${split}`
}
function countryOf(r: Row): string | null {
  return props.companies.find((c) => c.id === r.company_id)?.country_code ?? null
}
function openCorrection(r: Row): void {
  notice.value = null
  correctDialog.value?.open(r as unknown as CorrectionTarget, countryOf(r))
}
function onCorrected(result: { workingDays: number; split: number }): void {
  notice.value = `Corrected: ${result.workingDays} working ${result.workingDays === 1 ? 'day' : 'days'}${result.split ? `, ${result.split} record${result.split === 1 ? '' : 's'} split off` : ''}. The balance follows.`
  void load()
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('leave_requests')
    .select(
      `id, person_id, company_id, leave_type_key, requires_document, deducts_balance, start_date, end_date, working_days, status, note, documents_to_follow,
       decision_note, cancellation_reason, cancellation_requested_at, cancellation_request_reason,
       cancellation_declined_at, cancellation_decline_note, created_at, decided_at, cancelled_at,
       person:people!leave_requests_person_id_fkey(full_name), company:companies(name), leave_type:leave_types(label),
       decider:people!leave_requests_decided_by_fkey(full_name), canceller:people!leave_requests_cancelled_by_fkey(full_name),
       corrections:leave_corrections(id, old_start, old_end, old_leave_type_key, old_working_days, new_start, new_end, new_leave_type_key, new_working_days, split_request_ids, note, corrected_at, corrector:people!leave_corrections_corrected_by_fkey(full_name))`,
    )
    .in('company_id', props.companyIds)
    .order('created_at', { ascending: false })
    .limit(500)
  if (err) {
    error.value = 'Could not load leave requests. Check your access and connection.'
    console.error('Leave requests load failed:', err.message)
  } else {
    requests.value = (data ?? []) as unknown as Row[]
  }
  loading.value = false
}

onMounted(load)
defineExpose({ reload: load })
</script>

<template>
  <div class="desk">
    <div class="tabs" role="tablist" aria-label="Manager desk">
      <button
        v-for="t in tabs"
        :key="t.id"
        class="tab"
        :class="{ active: tab === t.id }"
        type="button"
        role="tab"
        :aria-selected="tab === t.id"
        @click="tab = t.id"
      >
        {{ t.label }}
        <span class="count" :class="{ urgent: t.urgent && t.count }">{{ t.count }}</span>
      </button>
    </div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <p v-if="notice" class="notice" role="status">{{ notice }}</p>
    <div v-if="loading" class="empty">Loading requests…</div>
    <template v-else>
      <div class="card">
        <div class="toolbar">
          <label class="search">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><circle cx="7" cy="7" r="4.5" /><path d="M10.5 10.5L14 14" /></svg>
            <input v-model="query" placeholder="Find a person" aria-label="Find a person" />
          </label>
          <select v-model="month" aria-label="Month">
            <option value="all">Any month</option>
            <option v-for="k in monthOptions" :key="k" :value="k">{{ MONTHS[Number(k.slice(5, 7)) - 1] }} {{ k.slice(0, 4) }}</option>
          </select>
          <select v-if="companies.length > 1" v-model="company" aria-label="Company">
            <option value="all">Every company</option>
            <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
          </select>
          <button v-if="filtered" class="linkish" type="button" @click="query = ''; month = 'all'; company = 'all'">Clear</button>
          <span class="records-count">
            <template v-if="filtered"><b>{{ shown.length }}</b> of {{ source.length }}</template>
            <template v-else><b>{{ source.length }}</b> {{ source.length === 1 ? 'record' : 'records' }}</template>
          </span>
        </div>

        <!-- Decisions and asks keep the action list: approve / reject / cancel / decline. -->
        <LeaveRequestsList
          v-if="tab === 'decide' || tab === 'asks'"
          :requests="shown"
          show-person
          show-company
          :empty-text="tab === 'decide' ? 'The queue is clear. Nothing is waiting on a decision.' : 'Nothing to unwind. People cancel their own leave until it starts; after that it lands here.'"
          @changed="load"
          @error="(m) => (error = m)"
        />

        <!-- The settled record: a table. -->
        <div v-else class="table-wrap">
          <div v-if="!shown.length" class="empty">{{ filtered ? 'Nothing matches those filters.' : tab === 'approved' ? 'No approved leave yet.' : 'Nothing cancelled or rejected.' }}</div>
          <table v-else>
            <thead>
              <tr>
                <th>Person</th>
                <th>Dates</th>
                <th class="num">Days</th>
                <th>{{ tab === 'approved' ? 'Approved by' : 'Cancelled / rejected by' }}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="r in shown" :key="r.id" :data-testid="`record-${r.id}`">
                <td>
                  <router-link class="person" :to="{ name: 'person', params: { personId: r.person_id } }"><b>{{ r.person?.full_name ?? '—' }}</b></router-link>
                  <small>{{ r.company?.name }} · {{ r.leave_type?.label ?? r.leave_type_key }}<template v-if="r.status === 'rejected'"> · rejected</template></small>
                  <small v-if="r.corrections?.length" class="corrections">
                    <span v-for="c in r.corrections" :key="c.id" class="correction">
                      Corrected {{ stamp(c.corrected_at) }} by {{ c.corrector?.full_name ?? 'someone' }}: {{ describe(c) }}<template v-if="c.note"> — “{{ c.note }}”</template>
                    </span>
                  </small>
                  <small v-if="tab === 'cancelled' && (r.cancellation_reason || r.decision_note)" class="reason">“{{ r.cancellation_reason || r.decision_note }}”</small>
                </td>
                <td class="dates">{{ shortDate(r.start_date) }}<template v-if="r.end_date !== r.start_date"> — {{ shortDate(r.end_date) }}</template> {{ r.start_date.slice(0, 4) }}</td>
                <td class="num"><b>{{ r.working_days }}</b></td>
                <td>
                  <template v-if="byWhom(r)">
                    <span :class="{ muted: byWhom(r)!.name === 'no author recorded' }">{{ byWhom(r)!.name }}</span>
                    <small>{{ stamp(byWhom(r)!.at) }}</small>
                  </template>
                  <span v-else class="muted">no author recorded</span>
                </td>
                <td class="actions">
                  <button v-if="canCorrect(r)" class="button secondary small-btn" type="button" @click="openCorrection(r)">Correct</button>
                  <LeaveRequestsList v-if="tab === 'approved'" :requests="[r]" compact @changed="load" @error="(m) => (error = m)" />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </template>
    <CorrectLeaveDialog ref="correctDialog" @corrected="onCorrected" />
  </div>
</template>

<style scoped>
.desk { display: grid; gap: 16px; }
.tabs { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px; padding: 6px; background: #eceeea; border-radius: 12px; }
.tab { display: inline-flex; align-items: center; justify-content: center; gap: 8px; padding: 12px 10px; border: 0; border-radius: 9px; background: transparent; color: var(--muted); font-size: 13px; font-weight: 600; }
.tab:hover { color: var(--ink); }
.tab.active { background: #fff; color: var(--ink); box-shadow: var(--shadow-sm); }
.count { display: inline-grid; place-items: center; min-width: 22px; height: 22px; padding: 0 7px; border-radius: 999px; background: #dfe4dc; color: var(--muted); font-size: 11px; font-weight: 700; }
.count.urgent { background: var(--green); color: #fff; }
.tab.active .count.urgent { background: var(--green-bright); }
.notice { padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin: 0; }
.toolbar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 14px 20px; border-bottom: 1px solid var(--line); background: #fbfcfa; }
.search { display: flex; align-items: center; gap: 8px; flex: 1; min-width: 200px; border: 1px solid var(--line-strong); border-radius: 9px; padding: 0 12px; background: #fff; color: var(--muted); }
.search input { border: 0; padding: 9px 0; flex: 1; font-size: 13px; background: transparent; min-width: 0; }
.search input:focus { outline: none; }
.search:focus-within { border-color: var(--green-bright); box-shadow: var(--ring); }
.toolbar select { border: 1px solid var(--line-strong); padding: 9px 10px; font-size: 12px; background: #fff; border-radius: 9px; }
.linkish { background: none; border: 0; color: var(--green); font-size: 12px; text-decoration: underline; text-underline-offset: 2px; padding: 0 4px; }
.records-count { margin-left: auto; font-size: 12px; color: var(--muted); }
.records-count b { color: var(--ink); }
td .person { text-decoration: none; color: var(--ink); }
td .person:hover b { color: var(--green); }
td small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
td .corrections { display: grid; gap: 2px; color: var(--green-deep); }
td .reason { color: var(--ink); }
td.dates { white-space: nowrap; }
td.num, th.num { text-align: right; }
td.num b { font-size: 16px; font-weight: 700; color: var(--green); }
.muted { color: var(--muted); font-style: italic; }
td.actions { white-space: nowrap; text-align: right; }
td.actions > * { display: inline-flex; vertical-align: middle; margin-left: 6px; }
.small-btn { padding: 7px 11px; font-size: 11px; }
@media (max-width: 720px) { .tabs { grid-template-columns: 1fr 1fr; } }
</style>
