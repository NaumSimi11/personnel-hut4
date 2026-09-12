<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { cancellationState } from '@/lib/leave'
import LeaveRequestsList, { type LeaveRequestRow } from '@/components/LeaveRequestsList.vue'

/**
 * The approver's queue (plan 036): pending requests and open cancellation
 * asks in the given companies, then recent decided ones. RLS already limits
 * rows to companies where the viewer holds leave.view or leave.approve;
 * the list offers actions only where leave.approve applies.
 */

const props = defineProps<{ companyIds: string[] }>()

const requests = ref<LeaveRequestRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const open = computed(() => requests.value.filter((r) => r.status === 'pending' || cancellationState(r) === 'open'))
const recent = computed(() => requests.value.filter((r) => !open.value.includes(r)))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('leave_requests')
    .select(
      `id, person_id, company_id, leave_type_key, requires_document, start_date, end_date, working_days, status, note, documents_to_follow,
       decision_note, cancellation_reason, cancellation_requested_at, cancellation_request_reason,
       cancellation_declined_at, cancellation_decline_note,
       person:people!leave_requests_person_id_fkey(full_name), company:companies(name), leave_type:leave_types(label)`,
    )
    .in('company_id', props.companyIds)
    .order('created_at', { ascending: false })
    .limit(200)
  if (err) {
    error.value = 'Could not load leave requests. Check your access and connection.'
    console.error('Leave requests load failed:', err.message)
  } else {
    requests.value = (data ?? []) as LeaveRequestRow[]
  }
  loading.value = false
}

onMounted(load)
defineExpose({ reload: load })
</script>

<template>
  <div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-if="loading" class="empty">Loading requests…</div>
    <template v-else>
      <div class="card section">
        <div class="card-head">
          <div>
            <h2>Waiting on a decision ({{ open.length }})</h2>
            <p>Pending requests and approved leave someone asks to cancel. Nobody decides their own.</p>
          </div>
        </div>
        <LeaveRequestsList :requests="open" show-person show-company empty-text="Nothing waiting." @changed="load" @error="(m) => (error = m)" />
      </div>
      <details class="card section">
        <summary class="card-head">
          <div>
            <h2>Recent ({{ recent.length }})</h2>
            <p>Approved, rejected and cancelled requests. Approved leave can still be cancelled by an approver.</p>
          </div>
        </summary>
        <LeaveRequestsList :requests="recent" show-person show-company empty-text="No decided requests yet." @changed="load" @error="(m) => (error = m)" />
      </details>
    </template>
  </div>
</template>

<style scoped>
.section { margin-bottom: 22px; }
summary { cursor: pointer; list-style: none; }
summary::-webkit-details-marker { display: none; }
</style>
