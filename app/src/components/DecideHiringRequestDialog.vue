<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'

/**
 * Send a hiring request back or reject it, with the reason the requester
 * will read (plan 042). The database (app.gate_hiring_request_transitions)
 * requires jobs.approve, refuses one's own request and an empty reason;
 * this dialog keeps what was typed when a save fails and never double-submits.
 */
export type DecisionTarget = { id: string; title: string; company: { name: string } | null }
type Mode = 'changes' | 'reject'

const emit = defineEmits<{ decided: [status: 'changes_requested' | 'rejected'] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const mode = ref<Mode>('changes')
const target = ref<DecisionTarget | null>(null)
const reason = ref('')
const error = ref<string | null>(null)
const busy = ref(false)

const title = computed(() => (mode.value === 'changes' ? 'Request changes' : 'Reject request'))
const prompt = computed(() =>
  mode.value === 'changes'
    ? 'What needs to change before this request can be approved? The requester reads this, edits the request and resubmits it.'
    : 'Why is this hiring request rejected? The requester reads this; a rejected request is closed.',
)

function open(next: Mode, t: DecisionTarget): void {
  mode.value = next
  target.value = t
  reason.value = ''
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

async function submit(): Promise<void> {
  if (!target.value || busy.value) return
  error.value = null
  const text = reason.value.trim()
  if (text.length < 3) {
    error.value = mode.value === 'changes' ? 'Say what needs to change.' : 'Say why the request is rejected.'
    return
  }
  busy.value = true
  const status = mode.value === 'changes' ? 'changes_requested' : 'rejected'
  const { data, error: err } = await supabase
    .from('hiring_requests')
    .update({ status, change_reason: text })
    .eq('id', target.value.id)
    .select('id')
    .maybeSingle()
  busy.value = false
  if (err || !data) {
    error.value = friendly(err?.message ?? 'row-level security')
    return
  }
  dialog.value?.close()
  emit('decided', status)
}

function friendly(message: string): string {
  if (message.includes('jobs.approve')) return 'Deciding needs the jobs.approve capability in this company.'
  if (message.includes('their own')) return 'You requested this hire — a different approver must decide it.'
  if (/row-level security/.test(message)) return 'You do not have permission to decide requests in this company.'
  return message
}
</script>

<template>
  <dialog ref="dialog" class="decide-dialog" aria-labelledby="decide-title" @cancel="busy && $event.preventDefault()">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Hiring request</div>
      <h2 id="decide-title">{{ title }}</h2>
      <p class="which"><b>{{ target?.title }}</b><template v-if="target?.company"> · {{ target.company.name }}</template></p>
      <p class="hint">{{ prompt }}</p>
      <fieldset :disabled="busy">
        <div class="field">
          <label for="decide-reason">{{ mode === 'changes' ? 'What needs to change' : 'Reason' }}</label>
          <textarea id="decide-reason" v-model="reason" rows="4" maxlength="2000" required></textarea>
        </div>
      </fieldset>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" :disabled="busy" @click="dialog?.close()">Cancel</button>
        <button class="button" :class="{ danger: mode === 'reject' }" type="submit" :disabled="busy">
          {{ busy ? 'Saving…' : mode === 'changes' ? 'Request changes' : 'Reject request' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.decide-dialog { border: 0; border-radius: 15px; padding: 0; width: min(520px, calc(100vw - 36px)); color: var(--ink); }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 6px; }
.which { margin: 0 0 6px; font-size: 13px; }
.hint { font-size: 12px; color: var(--muted); line-height: 1.6; margin: 0 0 16px; }
fieldset { border: 0; padding: 0; margin: 0; }
textarea { width: 100%; border: 1px solid var(--line-strong); padding: 11px 13px; background: #fcfdfb; color: var(--ink); font: inherit; font-size: 13px; border-radius: var(--radius-sm); }
textarea:focus { outline: none; border-color: var(--green-bright); box-shadow: var(--ring); background: #fff; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.button.danger { background: linear-gradient(135deg, #c04a4a, var(--red) 60%, #7e2c2c); }
</style>
