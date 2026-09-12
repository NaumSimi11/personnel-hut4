<script setup lang="ts">
import { computed } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { cancellationState, friendlyLeaveError, leaveActions, leaveStatusLabel, type LeaveAction } from '@/lib/leave'

/**
 * Leave requests as rows with the actions the viewer may take (plan 036).
 * lib/leave decides what to offer; decide_leave / cancel_leave /
 * request_leave_cancellation / decline_leave_cancellation decide for real.
 */

export type LeaveRequestRow = {
  id: string
  person_id: string
  company_id: string
  leave_type_key: string
  start_date: string
  end_date: string
  working_days: number
  status: string
  note: string | null
  documents_to_follow: boolean
  decision_note: string | null
  cancellation_reason: string | null
  cancellation_requested_at: string | null
  cancellation_request_reason: string | null
  cancellation_declined_at: string | null
  cancellation_decline_note: string | null
  person?: { full_name: string } | null
  company?: { name: string } | null
  leave_type?: { label: string } | null
}

const props = withDefaults(
  defineProps<{ requests: LeaveRequestRow[]; showPerson?: boolean; showCompany?: boolean; emptyText?: string }>(),
  { showPerson: false, showCompany: false, emptyText: 'No leave requests.' },
)
const emit = defineEmits<{ changed: []; error: [message: string] }>()

const auth = useAuthStore()
const today = computed(() => todayDb())

function actionsFor(r: LeaveRequestRow): LeaveAction[] {
  return leaveActions(r, { personId: auth.personId, canApprove: auth.can(r.company_id, 'leave.approve') }, today.value)
}

function canAnswerAsk(r: LeaveRequestRow): boolean {
  return cancellationState(r) === 'open' && auth.can(r.company_id, 'leave.approve') && auth.personId !== r.person_id
}

function badgeClass(r: LeaveRequestRow): string {
  if (cancellationState(r) === 'open') return 'amber'
  return { pending: 'amber', approved: 'green', rejected: '', cancelled: '' }[r.status] ?? ''
}

function badgeText(r: LeaveRequestRow): string {
  return cancellationState(r) === 'open' ? 'Cancellation asked' : leaveStatusLabel(r.status)
}

function meta(r: LeaveRequestRow): string {
  const parts = [
    `${r.start_date}${r.end_date !== r.start_date ? ` → ${r.end_date}` : ''}`,
    `${r.working_days} working ${Number(r.working_days) === 1 ? 'day' : 'days'}`,
  ]
  if (props.showCompany && r.company?.name) parts.push(r.company.name)
  if (r.documents_to_follow) parts.push('certificate to follow')
  return parts.join(' · ')
}

function detail(r: LeaveRequestRow): string | null {
  if (cancellationState(r) === 'open') return `Asks to cancel: ${r.cancellation_request_reason ?? ''}`.trim()
  if (r.status === 'cancelled' && r.cancellation_reason) return `Cancelled: ${r.cancellation_reason}`
  if (r.status === 'rejected' && r.decision_note) return `Rejected: ${r.decision_note}`
  if (cancellationState(r) === 'declined' && r.cancellation_decline_note) return `Cancellation declined: ${r.cancellation_decline_note}`
  return r.note
}

async function run(r: LeaveRequestRow, key: LeaveAction['key'] | 'decline-ask'): Promise<void> {
  const call = async () => {
    switch (key) {
      case 'approve':
        return supabase.rpc('decide_leave', { p_request_id: r.id, p_decision: 'approved' })
      case 'reject': {
        const note = window.prompt('Why is this request rejected?')
        if (note === null) return null
        return supabase.rpc('decide_leave', { p_request_id: r.id, p_decision: 'rejected', p_note: note })
      }
      case 'cancel': {
        const reason = window.prompt('Why is this leave cancelled?')
        if (reason === null) return null
        return supabase.rpc('cancel_leave', { p_request_id: r.id, p_reason: reason })
      }
      case 'ask': {
        const reason = window.prompt('Why should this leave be cancelled? HR will decide.')
        if (reason === null) return null
        return supabase.rpc('request_leave_cancellation', { p_request_id: r.id, p_reason: reason })
      }
      case 'decline-ask': {
        const note = window.prompt('Why does the leave stand?')
        if (note === null) return null
        return supabase.rpc('decline_leave_cancellation', { p_request_id: r.id, p_note: note })
      }
    }
  }
  const res = await call()
  if (!res) return
  if (res.error) {
    console.error(`Leave action ${key} failed:`, res.error.message)
    emit('error', friendlyLeaveError(res.error.message))
    return
  }
  emit('changed')
}
</script>

<template>
  <div v-if="!requests.length" class="empty">{{ emptyText }}</div>
  <div v-else>
    <div v-for="r in requests" :key="r.id" class="req-row" :data-testid="`leave-${r.id}`">
      <div class="row-text">
        <strong>
          <router-link v-if="showPerson && r.person" :to="{ name: 'person', params: { personId: r.person_id } }">
            {{ r.person.full_name }}
          </router-link>
          <template v-if="showPerson && r.person"> · </template>
          {{ r.leave_type?.label ?? r.leave_type_key }}
        </strong>
        <small>{{ meta(r) }}</small>
        <small v-if="detail(r)" class="detail">{{ detail(r) }}</small>
      </div>
      <span class="badge" :class="badgeClass(r)">{{ badgeText(r) }}</span>
      <div class="row-actions">
        <template v-if="canAnswerAsk(r)">
          <button class="button small-btn" type="button" @click="run(r, 'cancel')">Cancel leave</button>
          <button class="button secondary small-btn" type="button" @click="run(r, 'decline-ask')">Decline ask</button>
        </template>
        <template v-else>
          <button
            v-for="a in actionsFor(r)"
            :key="a.key"
            class="button small-btn"
            :class="{ secondary: a.key !== 'approve' }"
            type="button"
            @click="run(r, a.key)"
          >
            {{ a.label }}
          </button>
        </template>
      </div>
    </div>
  </div>
</template>

<style scoped>
.req-row { display: flex; align-items: center; gap: 13px; padding: 14px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.row-text .detail { color: var(--ink); }
.row-actions { display: flex; gap: 6px; flex-wrap: wrap; }
.small-btn { padding: 7px 11px; font-size: 11px; }
</style>
