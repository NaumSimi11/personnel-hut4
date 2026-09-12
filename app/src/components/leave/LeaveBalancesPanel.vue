<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { friendlyLeaveError } from '@/lib/leave'
import type { Balance } from '@/components/LeaveCard.vue'
import { EMPLOYED_STATUSES } from '@/lib/leave'

/**
 * Balances for everyone employed in a company in a given year (plan 036).
 * leave_balance does the arithmetic; set_leave_entitlement and
 * adjust_leave_balance (leave.adjust) are the only ways to change a number,
 * each with a reason kept in leave_adjustments.
 */

type PersonRow = { person_id: string; full_name: string; balance: Balance | null }

const props = defineProps<{ companyId: string; entitlementDefault: number }>()

const auth = useAuthStore()
const thisYear = Number(todayDb().slice(0, 4))
const year = ref(thisYear)
const rows = ref<PersonRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const canAdjust = computed(() => auth.can(props.companyId, 'leave.adjust'))
const years = computed(() => [thisYear - 1, thisYear, thisYear + 1])
const missing = computed(() => rows.value.filter((r) => !r.balance?.exists))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('employment_periods')
    .select('person_id, person:people!employment_periods_person_id_fkey(full_name)')
    .eq('company_id', props.companyId)
    .in('status', EMPLOYED_STATUSES)
  if (err) {
    error.value = 'Could not load the people in this company.'
    console.error('Balances load failed:', err.message)
    loading.value = false
    return
  }
  const people = Array.from(
    new Map((data ?? []).map((p) => [p.person_id, (p.person as { full_name: string } | null)?.full_name ?? '—'])).entries(),
  ).sort((a, b) => a[1].localeCompare(b[1]))
  rows.value = await Promise.all(
    people.map(async ([person_id, full_name]) => {
      const res = await supabase.rpc('leave_balance', { p_person_id: person_id, p_company_id: props.companyId, p_year: year.value })
      if (res.error) console.error('leave_balance failed:', res.error.message)
      return { person_id, full_name, balance: (res.data as Balance | null) ?? null }
    }),
  )
  loading.value = false
}

async function setEntitlement(row: PersonRow): Promise<void> {
  const current = row.balance?.exists ? row.balance.entitlement : props.entitlementDefault
  const raw = window.prompt(`Yearly entitlement for ${row.full_name} in ${year.value} (days)`, String(current))
  if (raw === null) return
  const reason = window.prompt('Why?')
  if (reason === null) return
  await call(supabase.rpc('set_leave_entitlement', {
    p_person_id: row.person_id,
    p_company_id: props.companyId,
    p_year: year.value,
    p_entitlement: Number(raw),
    p_reason: reason,
  }), `Entitlement set for ${row.full_name}.`)
}

async function adjust(row: PersonRow): Promise<void> {
  const raw = window.prompt(`Adjust ${row.full_name}'s ${year.value} balance by how many days? (negative to remove)`, '1')
  if (raw === null) return
  const reason = window.prompt('Why?')
  if (reason === null) return
  await call(supabase.rpc('adjust_leave_balance', {
    p_person_id: row.person_id,
    p_company_id: props.companyId,
    p_year: year.value,
    p_days: Number(raw),
    p_reason: reason,
  }), `Balance adjusted for ${row.full_name}.`)
}

async function setAllMissing(): Promise<void> {
  const reason = window.prompt(`Give everyone without a ${year.value} balance the company default (${props.entitlementDefault} days). Why?`, 'Yearly entitlement')
  if (reason === null) return
  let failed = false
  for (const row of missing.value) {
    const res = await supabase.rpc('set_leave_entitlement', {
      p_person_id: row.person_id,
      p_company_id: props.companyId,
      p_year: year.value,
      p_entitlement: props.entitlementDefault,
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

watch([() => props.companyId, year], load)
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
    <div v-else class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Person</th><th>Entitlement</th><th>Carried over</th><th>Adjusted</th><th>Taken</th><th>Pending</th><th>Left</th><th v-if="canAdjust"></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.person_id" :data-testid="`balance-row-${r.person_id}`">
            <td><router-link :to="{ name: 'person', params: { personId: r.person_id } }">{{ r.full_name }}</router-link></td>
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
              <button class="button secondary small-btn" type="button" @click="setEntitlement(r)">Entitlement</button>
              <button v-if="r.balance?.exists" class="button secondary small-btn" type="button" @click="adjust(r)">Adjust</button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<style scoped>
.head-actions { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.year { border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; background: #fff; }
.small-btn { padding: 7px 11px; font-size: 11px; }
.in-card, .notice { margin: 14px 24px 0; }
.notice { padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.muted { color: var(--muted); font-size: 11px; }
.actions { display: flex; gap: 6px; white-space: nowrap; }
</style>
