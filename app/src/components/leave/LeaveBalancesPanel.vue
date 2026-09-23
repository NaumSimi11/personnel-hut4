<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { todayDb } from '@/lib/compensation'
import { filterBalanceRows, friendlyLeaveError } from '@/lib/leave'
import type { Balance } from '@/components/LeaveCard.vue'
import { EMPLOYED_STATUSES } from '@/lib/leave'

/**
 * Balances for everyone employed in a company in a given year (plan 036).
 * leave_balance does the arithmetic; set_leave_entitlement and
 * adjust_leave_balance (leave.adjust) are the only ways to change a number,
 * each with a reason kept in leave_adjustments.
 */

type Company = { id: string; name: string; leave_entitlement_days: number }
type PersonRow = { person_id: string; full_name: string; company: Company; balance: Balance | null }

const props = defineProps<{ companies: Company[] }>()

const auth = useAuthStore()
const dialogs = useDialogStore()
const thisYear = Number(todayDb().slice(0, 4))
const year = ref(thisYear)
const query = ref('')
const rows = ref<PersonRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const canAdjust = computed(() => props.companies.some((c) => auth.can(c.id, 'leave.adjust')))
const many = computed(() => props.companies.length > 1)
const canAdjustIn = (c: Company) => auth.can(c.id, 'leave.adjust')
const years = computed(() => [thisYear - 1, thisYear, thisYear + 1])
const shown = computed(() => filterBalanceRows(rows.value, query.value))
/**
 * Counted from what is on screen, not from everyone. Otherwise a search for
 * one name leaves a button offering to create balances for forty people, and
 * the number beside it is the only warning you get.
 */
const missing = computed(() => shown.value.filter((r) => !r.balance?.exists))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('employment_periods')
    .select('person_id, company_id, person:people!employment_periods_person_id_fkey(full_name)')
    .in('company_id', props.companies.map((c) => c.id))
    .in('status', EMPLOYED_STATUSES)
  if (err) {
    error.value = 'Could not load the people in this company.'
    console.error('Balances load failed:', err.message)
    loading.value = false
    return
  }
  // One row per person and company (a transfer mid-year shows in both).
  const seen = new Map<string, { person_id: string; full_name: string; company: Company }>()
  for (const p of data ?? []) {
    const company = props.companies.find((c) => c.id === p.company_id)
    if (company) seen.set(`${p.person_id}/${p.company_id}`, { person_id: p.person_id, full_name: (p.person as { full_name: string } | null)?.full_name ?? '—', company })
  }
  const people = Array.from(seen.values()).sort((a, b) => a.company.name.localeCompare(b.company.name) || a.full_name.localeCompare(b.full_name))
  rows.value = await Promise.all(
    people.map(async (p) => {
      const res = await supabase.rpc('leave_balance', { p_person_id: p.person_id, p_company_id: p.company.id, p_year: year.value })
      if (res.error) console.error('leave_balance failed:', res.error.message)
      return { ...p, balance: (res.data as Balance | null) ?? null }
    }),
  )
  loading.value = false
}

async function setEntitlement(row: PersonRow): Promise<void> {
  const current = row.balance?.exists ? row.balance.entitlement : row.company.leave_entitlement_days
  const answer = await dialogs.askReason({
    title: `Yearly entitlement for ${row.full_name} in ${year.value}`,
    hint: `${row.company.name} gives ${row.company.leave_entitlement_days} days by default. The change and its reason are recorded.`,
    value: { label: 'Days', initial: current, min: 0 },
    confirmLabel: 'Set entitlement',
  })
  if (!answer || answer.value === null) return
  await call(supabase.rpc('set_leave_entitlement', {
    p_person_id: row.person_id,
    p_company_id: row.company.id,
    p_year: year.value,
    p_entitlement: answer.value,
    p_reason: answer.reason,
  }), `Entitlement set for ${row.full_name}.`)
}

async function adjust(row: PersonRow): Promise<void> {
  const answer = await dialogs.askReason({
    title: `Adjust ${row.full_name}'s ${year.value} balance`,
    hint: 'Days are added to (or taken from) what is left this year; the change and its reason are recorded.',
    value: { label: 'Days to add (negative to remove)', initial: 1 },
    confirmLabel: 'Adjust balance',
  })
  if (!answer || answer.value === null) return
  await call(supabase.rpc('adjust_leave_balance', {
    p_person_id: row.person_id,
    p_company_id: row.company.id,
    p_year: year.value,
    p_days: answer.value,
    p_reason: answer.reason,
  }), `Balance adjusted for ${row.full_name}.`)
}

async function setAllMissing(): Promise<void> {
  const targets = missing.value.filter((r) => canAdjustIn(r.company))
  const answer = await dialogs.askReason({
    title: `Give everyone without a ${year.value} balance their company's default entitlement?`,
    hint: `${targets.length} ${targets.length === 1 ? 'person gets' : 'people get'} their company's default days; the reason is recorded on each balance.`,
    initial: 'Yearly entitlement',
    confirmLabel: 'Create balances',
  })
  if (!answer) return
  const reason = answer.reason
  let failed = false
  for (const row of targets) {
    const res = await supabase.rpc('set_leave_entitlement', {
      p_person_id: row.person_id,
      p_company_id: row.company.id,
      p_year: year.value,
      p_entitlement: row.company.leave_entitlement_days,
      p_reason: reason,
    })
    if (res.error) {
      error.value = friendlyLeaveError(res.error.message)
      console.error('set_leave_entitlement failed:', res.error.message)
      failed = true
      break
    }
  }
  notice.value = failed ? null : 'Balances created.'
  await load()
}

async function call(p: PromiseLike<{ error: { message: string } | null }>, done: string): Promise<void> {
  error.value = null
  const res = await p
  if (res.error) {
    error.value = friendlyLeaveError(res.error.message)
    console.error('Leave balance change failed:', res.error.message)
    return
  }
  notice.value = done
  await load()
}

watch([() => props.companies, year], load)
onMounted(load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Balances</h2>
        <p>Entitlement + carry-over + adjustments − taken. Pending requests are held aside until decided.</p>
      </div>
      <div class="head-actions">
        <input
          v-model="query"
          class="search"
          type="search"
          aria-label="Search balances"
          :placeholder="many ? 'Name or company…' : 'Name…'"
          data-testid="balance-search"
        />
        <select v-model="year" aria-label="Year" class="year">
          <option v-for="y in years" :key="y" :value="y">{{ y }}</option>
        </select>
        <button v-if="canAdjust && missing.length" class="button secondary small-btn" type="button" @click="setAllMissing">
          Set default for {{ missing.length }} without a balance
        </button>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <p v-if="notice" class="notice" role="status">{{ notice }}</p>
    <div v-if="loading" class="empty">Loading balances…</div>
    <div v-else-if="!rows.length" class="empty">Nobody is employed here.</div>
    <div v-else-if="!shown.length" class="empty">Nobody here matches “{{ query.trim() }}”.</div>
    <div v-else class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Person</th><th v-if="many">Company</th><th>Entitlement</th><th>Carried over</th><th>Adjusted</th><th>Taken</th><th>Pending</th><th>Left</th><th v-if="canAdjust"></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in shown" :key="r.person_id + r.company.id" :data-testid="`balance-row-${r.person_id}`">
            <td><router-link :to="{ name: 'person', params: { personId: r.person_id } }">{{ r.full_name }}</router-link></td>
            <td v-if="many">{{ r.company.name }}</td>
            <template v-if="r.balance?.exists">
              <td>{{ r.balance.entitlement }}</td>
              <td>
                {{ r.balance.carry_over }}
                <small v-if="r.balance.carry_over" class="muted">until {{ r.balance.carry_over_expires_on }}{{ r.balance.carry_over_expired ? ' (expired)' : '' }}</small>
              </td>
              <td>{{ r.balance.adjustments }}</td>
              <td>{{ r.balance.used }}</td>
              <td>{{ r.balance.pending }}</td>
              <td><strong>{{ r.balance.remaining }}</strong></td>
            </template>
            <td v-else colspan="6" class="muted">No {{ year }} balance yet.</td>
            <td v-if="canAdjust" class="actions">
              <template v-if="canAdjustIn(r.company)">
                <button class="button secondary small-btn" type="button" @click="setEntitlement(r)">Entitlement</button>
                <button v-if="r.balance?.exists" class="button secondary small-btn" type="button" @click="adjust(r)">Adjust</button>
              </template>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<style scoped>
.head-actions { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.search { font-size: 12px; padding: 8px 10px; min-width: 200px; flex: 1 1 200px; }
.year { border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; background: #fff; }
.small-btn { padding: 7px 11px; font-size: 11px; }
.in-card, .notice { margin: 14px 24px 0; }
.notice { padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.muted { color: var(--muted); font-size: 11px; }
.actions { display: flex; gap: 6px; white-space: nowrap; }
</style>
