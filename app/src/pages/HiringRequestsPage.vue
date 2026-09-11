<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import RequestHireDialog from '@/components/RequestHireDialog.vue'

type HiringRequestRow = {
  id: string
  title: string
  reason: string | null
  headcount: number
  target_start_date: string | null
  status: string
  change_reason: string | null
  requested_by: string | null
  decided_at: string | null
  company: { name: string } | null
  requester: { full_name: string } | null
  manager: { full_name: string } | null
}

const requests = ref<HiringRequestRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const actionError = ref<string | null>(null)
const busyId = ref<string | null>(null)
const requestDialog = ref<InstanceType<typeof RequestHireDialog> | null>(null)

function badgeClass(status: string): string {
  if (status === 'approved') return 'green'
  if (status === 'submitted') return 'amber'
  if (status === 'changes_requested') return 'blue'
  return ''
}

function canDecide(status: string): boolean {
  return status === 'submitted' || status === 'changes_requested'
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('hiring_requests')
    .select(
      `id, title, reason, headcount, target_start_date, status, change_reason,
       requested_by, decided_at,
       company:companies(name),
       requester:people!hiring_requests_requested_by_fkey(full_name),
       manager:people!hiring_requests_hiring_manager_id_fkey(full_name)`,
    )
    .order('created_at', { ascending: false })
  if (err) {
    error.value = 'Could not load hiring requests. Check your access and connection.'
    console.error('Hiring requests load failed:', err.message)
  } else {
    requests.value = (data ?? []) as HiringRequestRow[]
  }
  loading.value = false
}

type Decision = { status: 'approved' | 'rejected' | 'changes_requested'; change_reason?: string }

async function performUpdate(row: HiringRequestRow, patch: Decision): Promise<void> {
  actionError.value = null
  busyId.value = row.id
  const { error: err } = await supabase.from('hiring_requests').update(patch).eq('id', row.id)
  busyId.value = null
  if (err) {
    actionError.value = friendlyDecisionError(err.message)
    return
  }
  await load()
}

function approve(row: HiringRequestRow): void {
  void performUpdate(row, { status: 'approved' })
}

function requestChanges(row: HiringRequestRow): void {
  const reason = window.prompt('What needs to change before this request can be approved?')
  if (!reason || !reason.trim()) return
  void performUpdate(row, { status: 'changes_requested', change_reason: reason.trim() })
}

function reject(row: HiringRequestRow): void {
  const reason = window.prompt('Why is this hiring request being rejected?')
  if (!reason || !reason.trim()) return
  void performUpdate(row, { status: 'rejected', change_reason: reason.trim() })
}

function friendlyDecisionError(message: string): string {
  if (message.includes('jobs.approve'))
    return 'Approving needs the jobs.approve capability in this company.'
  if (message.includes('their own'))
    return 'You requested this hire — a different approver must decide it.'
  return message
}

onMounted(load)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">Recruitment</div>
        <h1>One role. Every handoff connected.</h1>
      </div>
      <div class="head-actions">
        <button class="button" type="button" @click="requestDialog?.open()">Request a hire</button>
      </div>
    </div>

    <div class="card">
      <div class="card-head">
        <div>
          <h2>Hiring requests</h2>
          <p>Every request, from submission to decision.</p>
        </div>
      </div>
      <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
      <template v-else>
        <p v-if="actionError" class="error-note" role="alert" style="margin: 16px 24px">
          {{ actionError }}
        </p>
        <div v-if="loading" class="empty">Loading hiring requests…</div>
        <div v-else-if="!requests.length" class="empty">
          No hiring requests yet. Request a hire to start the journey.
        </div>
        <div v-else>
          <div v-for="r in requests" :key="r.id" class="request-row">
            <div class="row-text">
              <strong>{{ r.title }}</strong>
              <small>
                {{ r.company?.name ?? '—' }} · requested by {{ r.requester?.full_name ?? '—' }} ·
                headcount {{ r.headcount }}
                <template v-if="r.target_start_date"> · start {{ r.target_start_date }}</template>
                <template v-if="r.manager?.full_name"> · manager {{ r.manager.full_name }}</template>
              </small>
              <p v-if="r.change_reason" class="change-reason">{{ r.change_reason }}</p>
            </div>
            <span class="badge" :class="badgeClass(r.status)">{{ r.status.replace('_', ' ') }}</span>
            <div v-if="canDecide(r.status)" class="row-actions">
              <button
                class="button secondary small-btn"
                type="button"
                :disabled="busyId === r.id"
                @click="approve(r)"
              >
                Approve
              </button>
              <button
                class="button secondary small-btn"
                type="button"
                :disabled="busyId === r.id"
                @click="requestChanges(r)"
              >
                Request changes
              </button>
              <button
                class="button secondary small-btn"
                type="button"
                :disabled="busyId === r.id"
                @click="reject(r)"
              >
                Reject
              </button>
            </div>
          </div>
        </div>
      </template>
    </div>

    <RequestHireDialog ref="requestDialog" @created="load" />
  </div>
</template>

<style scoped>
.page-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
}
.head-actions { display: flex; gap: 9px; flex-wrap: wrap; }
h1 { margin-bottom: 24px; }
.request-row {
  display: flex;
  align-items: center;
  gap: 13px;
  padding: 15px 24px;
  border-top: 1px solid #edf0eb;
  flex-wrap: wrap;
}
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.change-reason { margin: 6px 0 0; font-size: 11px; color: var(--amber); }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
