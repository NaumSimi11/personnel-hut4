<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { EMPLOYED_STATUSES } from '@/lib/leave'
import LeaveRequestDialog, { type LeaveSubject } from '@/components/LeaveRequestDialog.vue'
import LeaveRequestsList, { type LeaveRequestRow } from '@/components/LeaveRequestsList.vue'

/**
 * One person's leave (plan 036): a balance per current employment for this
 * year and their requests. On My workspace the person requests for
 * themselves; on a profile an approver records leave on their behalf.
 * RLS on leave_requests / leave_balances is the real gate.
 */

type Employment = {
  id: string
  company_id: string
  status: string
  company: { name: string; country_code: string | null } | null
  location: { country_code: string | null } | null
}

export type Balance = {
  exists: boolean
  entitlement: number
  carry_over: number
  carry_over_expires_on: string | null
  carry_over_expired: boolean
  adjustments: number
  used: number
  carry_over_used: number
  pending: number
  remaining: number
  carry_over_remaining: number
}

const props = withDefaults(defineProps<{ personId: string; personName?: string; title?: string }>(), {
  personName: '',
  title: 'Leave',
})

const auth = useAuthStore()
const year = Number(todayDb().slice(0, 4))
const employments = ref<Employment[]>([])
const balances = ref<Record<string, Balance>>({})
const requests = ref<LeaveRequestRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const dialog = ref<InstanceType<typeof LeaveRequestDialog> | null>(null)

const self = computed(() => auth.personId === props.personId)
const current = computed(() => employments.value.filter((e) => EMPLOYED_STATUSES.includes(e.status)))
const visible = computed(
  () =>
    self.value ||
    auth.isAdmin ||
    employments.value.some((e) => auth.can(e.company_id, 'leave.view') || auth.can(e.company_id, 'leave.approve')),
)

function subjectFor(e: Employment): LeaveSubject {
  return {
    personId: props.personId,
    personName: props.personName,
    companyId: e.company_id,
    companyName: e.company?.name ?? '',
    countryCode: e.location?.country_code ?? e.company?.country_code ?? null,
    onBehalf: !self.value,
  }
}

function canRecord(e: Employment): boolean {
  return self.value || auth.can(e.company_id, 'leave.approve')
}

function adjustedLabel(b: Balance): string {
  if (!b.adjustments) return 'entitlement'
  const sign = b.adjustments > 0 ? '+' : ''
  return `entitlement (${sign}${b.adjustments} adjusted)`
}

function carryLabel(b: Balance): string {
  const until = b.carry_over_expires_on ? `, until ${b.carry_over_expires_on}` : ''
  return `carried over${until}${b.carry_over_expired ? ' (expired)' : ''}`
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [empRes, reqRes] = await Promise.all([
    supabase
      .from('employment_periods')
      .select('id, company_id, status, company:companies(name, country_code), location:locations(country_code)')
      .eq('person_id', props.personId)
      .order('start_date', { ascending: false }),
    supabase
      .from('leave_requests')
      .select(
        `id, person_id, company_id, leave_type_key, start_date, end_date, working_days, status, note, documents_to_follow,
         decision_note, cancellation_reason, cancellation_requested_at, cancellation_request_reason,
         cancellation_declined_at, cancellation_decline_note, company:companies(name), leave_type:leave_types(label)`,
      )
      .eq('person_id', props.personId)
      .order('start_date', { ascending: false })
      .limit(50),
  ])
  if (empRes.error || reqRes.error) {
    error.value = 'Could not load leave. Check your access and connection.'
    console.error('Leave load failed:', empRes.error?.message ?? reqRes.error?.message)
    loading.value = false
    return
  }
  employments.value = (empRes.data ?? []) as Employment[]
  requests.value = (reqRes.data ?? []) as LeaveRequestRow[]
  const rows = await Promise.all(
    current.value.map(async (e) => {
      const { data, error: err } = await supabase.rpc('leave_balance', {
        p_person_id: props.personId,
        p_company_id: e.company_id,
        p_year: year,
      })
      if (err) console.error('leave_balance failed:', err.message)
      return [e.company_id, (data ?? null) as Balance | null] as const
    }),
  )
  balances.value = Object.fromEntries(rows.filter((r): r is readonly [string, Balance] => r[1] !== null))
  loading.value = false
}

function onSubmitted(result: { status: string; workingDays: number }): void {
  notice.value =
    result.status === 'approved'
      ? `Recorded: ${result.workingDays} working days.`
      : `Sent for approval: ${result.workingDays} working days.`
  void load()
}

onMounted(load)
defineExpose({ reload: load })
</script>

<template>
  <div v-if="visible" class="card">
    <div class="card-head">
      <div>
        <h2>{{ title }}</h2>
        <p>{{ year }} balances per employment; requests go to whoever approves leave in that company.</p>
      </div>
      <div class="head-actions">
        <button
          v-for="e in current.filter(canRecord)"
          :key="e.id"
          class="button"
          type="button"
          :data-testid="`request-leave-${e.company_id}`"
          @click="dialog?.open(subjectFor(e))"
        >
          {{ self ? 'Request leave' : 'Record leave' }}{{ current.length > 1 ? ` · ${e.company?.name}` : '' }}
        </button>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <p v-if="notice" class="notice" role="status">{{ notice }}</p>
    <div v-if="loading" class="empty">Loading leave…</div>
    <template v-else>
      <div v-if="current.length" class="rails">
        <div v-for="e in current" :key="e.id" class="rail" :data-testid="`balance-${e.company_id}`">
          <div class="rail-company">{{ e.company?.name }}</div>
          <template v-if="balances[e.company_id]?.exists">
            <div class="stat"><b>{{ balances[e.company_id].remaining }}</b><span>days left</span></div>
            <div class="stat"><b>{{ balances[e.company_id].used }}</b><span>taken</span></div>
            <div class="stat"><b>{{ balances[e.company_id].pending }}</b><span>pending</span></div>
            <div class="stat">
              <b>{{ balances[e.company_id].carry_over_remaining }}</b>
              <span>{{ carryLabel(balances[e.company_id]) }}</span>
            </div>
            <div class="stat muted">
              <b>{{ balances[e.company_id].entitlement }}</b>
              <span>{{ adjustedLabel(balances[e.company_id]) }}</span>
            </div>
          </template>
          <small v-else class="no-balance">No {{ year }} balance yet — HR sets the entitlement from Leave → Balances.</small>
        </div>
      </div>
      <LeaveRequestsList
        :requests="requests"
        show-company
        empty-text="No leave requests yet."
        @changed="load"
        @error="(m) => (error = m)"
      />
    </template>
    <LeaveRequestDialog ref="dialog" @submitted="onSubmitted" />
  </div>
</template>

<style scoped>
.head-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.in-card, .notice { margin: 14px 24px 0; }
.notice { padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.rails { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 14px; padding: 18px 24px; }
.rail { border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; display: flex; flex-wrap: wrap; gap: 12px 18px; }
.rail-company { width: 100%; font-size: 11px; font-weight: 600; }
.stat b { display: block; font-size: 20px; font-weight: 600; }
.stat span { font-size: 10px; color: var(--muted); }
.stat.muted b { font-size: 14px; }
.no-balance { font-size: 11px; color: var(--muted); }
</style>
