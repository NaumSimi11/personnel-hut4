<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { cancellationState, friendlyLeaveError, leaveActions, leaveStatusLabel, type LeaveAction } from '@/lib/leave'
import { notifyLeave } from '@/lib/leaveApi'
import { signedDocumentUrl, uploadDocument, validateDocumentFile } from '@/lib/documents'

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
  requires_document?: boolean
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
  defineProps<{ requests: LeaveRequestRow[]; showPerson?: boolean; showCompany?: boolean; emptyText?: string; compact?: boolean }>(),
  { showPerson: false, showCompany: false, emptyText: 'No leave requests.', compact: false },
)
const emit = defineEmits<{ changed: []; error: [message: string] }>()

const auth = useAuthStore()
const today = computed(() => todayDb())

// Certificates (ported from Field Notebook): a sick-leave request shows its
// attached documents; the person or an approver can add one while the
// request is pending or approved. The upload goes through the documents
// module (medical_certificate, person and HR) and attach_leave_document.
type AttachedDoc = { id: string; title: string; original_name: string | null; storage_path: string }
const attached = ref<Record<string, AttachedDoc[]>>({})
const uploading = ref<string | null>(null)

async function loadAttached(): Promise<void> {
  const ids = props.requests.filter((r) => r.requires_document).map((r) => r.id)
  if (!ids.length) {
    attached.value = {}
    return
  }
  const { data, error } = await supabase
    .from('leave_request_documents')
    .select('request_id, document_id, document:documents(id, title, original_name, storage_path)')
    .in('request_id', ids)
  if (error) {
    console.error('Leave documents load failed:', error.message)
    return
  }
  // A viewer without documents.view still learns that a certificate exists;
  // only those who may read it get a link.
  const map: Record<string, AttachedDoc[]> = {}
  for (const row of data ?? []) {
    const d = (row.document as unknown as AttachedDoc | null) ?? { id: row.document_id, title: 'Certificate provided', original_name: null, storage_path: '' }
    map[row.request_id] = [...(map[row.request_id] ?? []), d]
  }
  attached.value = map
}
watch(() => props.requests, loadAttached, { immediate: true })

function docState(r: LeaveRequestRow): 'provided' | 'to_follow' | 'missing' | null {
  if (!r.requires_document) return null
  if (attached.value[r.id]?.length) return 'provided'
  return r.documents_to_follow ? 'to_follow' : 'missing'
}

function canAttach(r: LeaveRequestRow): boolean {
  if (!r.requires_document || (r.status !== 'pending' && r.status !== 'approved')) return false
  // The person may upload while the request has no certificate (0029); HR needs documents.upload.
  if (auth.personId === r.person_id) return !attached.value[r.id]?.length
  return auth.can(r.company_id, 'documents.upload')
}

async function attach(r: LeaveRequestRow, event: Event): Promise<void> {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  const problem = validateDocumentFile(file)
  if (problem) {
    emit('error', problem)
    return
  }
  uploading.value = r.id
  try {
    const doc = await uploadDocument({
      companyId: r.company_id,
      personId: r.person_id,
      file,
      form: { title: `Medical certificate · ${r.start_date}`, categoryKey: 'medical_certificate', visibility: 'person_and_hr', note: '' },
    })
    const { error } = await supabase.rpc('attach_leave_document', { p_request_id: r.id, p_document_id: doc.id })
    if (error) throw new Error(friendlyLeaveError(error.message))
    await loadAttached()
  } catch (e) {
    const message = e instanceof Error ? e.message : 'Upload failed.'
    console.error('Certificate upload failed:', message)
    emit('error', message)
  } finally {
    uploading.value = null
  }
}

async function openDoc(d: AttachedDoc): Promise<void> {
  const tab = window.open('', '_blank')
  try {
    const url = await signedDocumentUrl(d.storage_path)
    if (tab) tab.location.href = url
    else window.location.href = url
  } catch (e) {
    tab?.close()
    emit('error', e instanceof Error ? e.message : 'Could not open the document.')
  }
}

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
  const docs = docState(r)
  if (docs === 'to_follow') parts.push('certificate to follow')
  if (docs === 'missing') parts.push('certificate missing')
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
  if (key === 'approve') void notifyLeave(r.id, 'approved')
  if (key === 'reject') void notifyLeave(r.id, 'rejected')
  if (key === 'ask') void notifyLeave(r.id, 'cancellation_asked')
  emit('changed')
}
</script>

<template>
  <!-- Compact: only the buttons, for a table cell that already shows the record. -->
  <div v-if="compact" class="compact-actions">
    <template v-for="r in requests" :key="r.id">
      <template v-if="canAnswerAsk(r)">
        <button class="button small-btn" type="button" @click="run(r, 'cancel')">Cancel leave</button>
        <button class="button secondary small-btn" type="button" @click="run(r, 'decline-ask')">Decline ask</button>
      </template>
      <button
        v-for="a in actionsFor(r)"
        v-else
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
  <div v-else-if="!requests.length" class="empty">{{ emptyText }}</div>
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
        <small v-if="docState(r)" class="docs">
          <template v-for="d in attached[r.id] ?? []" :key="d.id">
            <a v-if="d.storage_path" href="#" @click.prevent="openDoc(d)">{{ d.original_name || d.title }}</a>
            <span v-else>{{ d.title }}</span>
          </template>
          <label v-if="canAttach(r)" class="attach">
            {{ uploading === r.id ? 'Uploading…' : attached[r.id]?.length ? 'Add another' : 'Add certificate' }}
            <input type="file" accept="application/pdf,image/jpeg,image/png" :disabled="uploading === r.id" @change="attach(r, $event)" />
          </label>
        </small>
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
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.row-text .detail { color: var(--ink); }
.docs { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
.docs a { color: var(--green); text-decoration: underline; }
.attach { color: var(--green); cursor: pointer; font-weight: 550; }
.attach input { display: none; }
.row-actions { display: flex; gap: 6px; flex-wrap: wrap; }
.small-btn { padding: 7px 11px; font-size: 11px; }
.compact-actions { display: inline-flex; gap: 6px; }
</style>
