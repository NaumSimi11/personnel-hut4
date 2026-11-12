<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { deliverNotifications, deliverySentence } from '@/lib/notificationsApi'
import { approvalSummary, type ApprovalItem } from '@/lib/myApprovals'

/**
 * My approvals (0104; spec 9.4): the hiring requests and offers whose current
 * step is mine — as the named approver, as the delegate of one on leave, or
 * through the capability the step names. The database decides who may act;
 * this lists and words it. Below, who covers my approvals while I am away.
 */
const auth = useAuthStore()
const dialogs = useDialogStore()
const items = ref<ApprovalItem[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const busyId = ref<string | null>(null)
const people = ref<{ id: string; full_name: string }[]>([])
const delegateId = ref('')
const savedDelegate = ref('')
const delegateBusy = ref(false)

const sorted = computed(() => [...items.value].sort((a, b) => b.created_at.localeCompare(a.created_at)))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [list, peopleRes, delegateRes] = await Promise.all([
    supabase.rpc('my_approvals'),
    supabase.from('people').select('id, full_name').is('archived_at', null).order('full_name'),
    auth.personId
      ? supabase.from('approval_delegates').select('delegate_id').eq('person_id', auth.personId).maybeSingle()
      : Promise.resolve({ data: null, error: null }),
  ])
  loading.value = false
  if (list.error) {
    console.error('my_approvals failed:', list.error.message)
    error.value = 'Could not load your approvals.'
    return
  }
  items.value = (list.data ?? []) as unknown as ApprovalItem[]
  people.value = (peopleRes.data ?? []).filter((p) => p.id !== auth.personId)
  savedDelegate.value = (delegateRes.data as { delegate_id?: string } | null)?.delegate_id ?? ''
  delegateId.value = savedDelegate.value
}

async function decide(item: ApprovalItem, decision: 'approved' | 'changes_requested' | 'rejected'): Promise<void> {
  let comment: string | null = null
  if (decision !== 'approved') {
    const answer = await dialogs.askReason({
      title: decision === 'changes_requested' ? 'Request changes' : item.subject_type === 'offer' ? 'Send the offer back' : 'Reject the request',
      eyebrow: item.title,
      hint:
        decision === 'changes_requested'
          ? 'The requester reads this, edits the request and resubmits it. It comes back to your step.'
          : item.subject_type === 'offer'
            ? 'The offer goes back to draft for its author, with your comment. The next submission starts the route again.'
            : 'A rejected request is closed for good; the requester reads why.',
      label: 'Comment',
      confirmLabel: decision === 'changes_requested' ? 'Request changes' : item.subject_type === 'offer' ? 'Send back' : 'Reject',
    })
    if (!answer) return
    comment = answer.reason
  }
  busyId.value = item.id
  error.value = null
  notice.value = null
  const { data, error: err } = await supabase.rpc('decide_approval', { p_task_id: item.id, p_decision: decision, p_comment: comment })
  busyId.value = null
  if (err) {
    console.error('decide_approval failed:', err.message)
    error.value = err.message
    return
  }
  const status = (data as { subject_status?: string } | null)?.subject_status ?? ''
  notice.value = `${decisionNotice(item, decision, status)} ${deliverySentence(await deliverNotifications())}`
  await load()
}

function decisionNotice(item: ApprovalItem, decision: string, status: string): string {
  if (decision !== 'approved') return item.subject_type === 'offer' ? 'Sent back to its author.' : decision === 'rejected' ? 'Rejected.' : 'Sent back for changes.'
  if (status === 'approved') return item.subject_type === 'offer' ? 'Offer approved — it can be sent to the candidate.' : 'Request approved.'
  return 'Your step is approved; the next approver is told.'
}

async function saveDelegate(): Promise<void> {
  if (!auth.personId) return
  delegateBusy.value = true
  error.value = null
  const res = delegateId.value
    ? await supabase.from('approval_delegates').upsert({ person_id: auth.personId, delegate_id: delegateId.value, updated_at: new Date().toISOString() })
    : await supabase.from('approval_delegates').delete().eq('person_id', auth.personId)
  delegateBusy.value = false
  if (res.error) {
    console.error('Saving the delegate failed:', res.error.message)
    error.value = 'Could not save who covers your approvals.'
    delegateId.value = savedDelegate.value
    return
  }
  savedDelegate.value = delegateId.value
  notice.value = delegateId.value ? 'Saved. While you are on approved leave, they decide your steps.' : 'Saved. Nobody covers your approvals while you are away.'
}

onMounted(load)
</script>

<template>
  <div class="approvals">
    <p v-if="notice" class="notice" role="status">{{ notice }}</p>
    <p v-if="error" class="error" role="alert">{{ error }}</p>

    <div class="card">
      <div class="card-head">
        <div>
          <h2>Waiting for you</h2>
          <p>Hiring requests and offers whose current step is yours.</p>
        </div>
      </div>
      <div v-if="loading" class="empty">Loading…</div>
      <div v-else-if="!sorted.length" class="empty" data-testid="approvals-empty">Nothing is waiting for you.</div>
      <div v-for="item in sorted" :key="item.id" class="item" :data-testid="`approval-${item.id}`">
        <div class="item-main">
          <div class="eyebrow">{{ item.company }} · {{ item.label }} · step {{ item.position }} of {{ item.steps }}<template v-if="item.as_delegate"> · as delegate</template></div>
          <strong>{{ item.title }}</strong>
          <small>{{ approvalSummary(item) }}</small>
          <router-link
            v-if="item.subject_type === 'offer' && item.detail?.application_id"
            class="link"
            :to="{ name: 'application', params: { applicationId: item.detail.application_id } }"
          >Open the application</router-link>
        </div>
        <div class="row-actions">
          <button class="button small-btn" type="button" :disabled="busyId === item.id" @click="decide(item, 'approved')">Approve</button>
          <button
            v-if="item.subject_type === 'request'"
            class="button secondary small-btn"
            type="button"
            :disabled="busyId === item.id"
            @click="decide(item, 'changes_requested')"
          >Request changes</button>
          <button class="button secondary small-btn danger-text" type="button" :disabled="busyId === item.id" @click="decide(item, 'rejected')">
            {{ item.subject_type === 'offer' ? 'Send back' : 'Reject' }}
          </button>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="card-head">
        <div>
          <h2>While I am away</h2>
          <p>On days you are on approved leave, this person decides the steps named for you.</p>
        </div>
      </div>
      <div class="delegate">
        <label for="approval-delegate">Delegate</label>
        <select id="approval-delegate" v-model="delegateId" :disabled="delegateBusy">
          <option value="">Nobody</option>
          <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
        </select>
        <button class="button secondary small-btn" type="button" :disabled="delegateBusy || delegateId === savedDelegate" @click="saveDelegate">Save</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.approvals { display: grid; gap: 16px; }
.item { display: flex; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding: 12px 0; border-top: 1px solid var(--line); }
.item-main { display: grid; gap: 2px; min-width: 0; }
.item-main small { color: var(--muted); }
.row-actions { display: flex; gap: 6px; flex-wrap: wrap; align-items: flex-start; }
.delegate { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.notice { margin: 0; }
.error { margin: 0; color: var(--red, #b42318); }
.link { font-size: 12px; }
</style>
