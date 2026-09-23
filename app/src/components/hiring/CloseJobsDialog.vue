<script setup lang="ts">
import { computed, ref } from 'vue'
import { closeQuestion, closeSelection, type CloseTarget } from '@/lib/closeJobs'

/**
 * Close the picked job openings — and, when asked, withdraw whoever is still
 * in play on them (plan 056). One dialog, one switch: closing is the act,
 * withdrawing the candidates is the "abandon" the maintainer asked for.
 *
 * The reason is required whenever candidates are withdrawn: it lands on every
 * application and in its timeline, so it is written for the candidate to read
 * back. Closing on its own may go unexplained.
 */
const emit = defineEmits<{ confirmed: [payload: { reason: string; withdraw: boolean }] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const rows = ref<CloseTarget[]>([])
const reason = ref('')
const withdraw = ref(false)
const error = ref<string | null>(null)

const selection = computed(() => closeSelection(rows.value))
/** Offered only when every picked company allows it — see CloseSelection. */
const offerWithdraw = computed(() => selection.value.inPlay > 0 && selection.value.mayWithdraw)
// Nothing to do only when there is nothing left to close AND nobody left to
// withdraw: an opening closed long ago can still have people waiting on it,
// which is most of the imported backlog.
const nothingToDo = computed(() => selection.value.toClose === 0 && !offerWithdraw.value)
const withdrawing = computed(() => withdraw.value && offerWithdraw.value)
const question = computed(() => closeQuestion(selection.value, withdrawing.value))
/**
 * Nothing left to close is not nothing to do: a selection of long-closed
 * openings with people still waiting on them is a withdrawal, and the heading
 * has to say so rather than offering to close none.
 */
const heading = computed(() => {
  const s = selection.value
  if (s.toClose === 0) {
    return offerWithdraw.value
      ? `Withdraw ${s.inPlay} candidate${s.inPlay === 1 ? '' : 's'}?`
      : 'Nothing left to close.'
  }
  if (s.toClose === 1) {
    return `Close ${rows.value.find((r) => r.status !== 'closed')?.title ?? 'this opening'}?`
  }
  return `Close ${s.toClose} openings?`
})

function open(picked: ReadonlyArray<CloseTarget>): void {
  rows.value = [...picked]
  reason.value = ''
  // Pre-ticked when anybody is waiting and the viewer may do it: leaving
  // them in play is the choice that needs the deliberate click, not the
  // other way round.
  const s = closeSelection(picked)
  withdraw.value = s.inPlay > 0 && s.mayWithdraw
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

function submit(): void {
  const trimmed = reason.value.trim()
  if (withdrawing.value && trimmed.length < 5) {
    error.value = 'Give the reason — it is written onto every application you withdraw.'
    return
  }
  if (trimmed.length > 2000) {
    error.value = 'Keep the reason to 2,000 characters or fewer.'
    return
  }
  dialog.value?.close()
  emit('confirmed', { reason: trimmed, withdraw: withdrawing.value })
}
</script>

<template>
  <dialog ref="dialog" class="close-dialog" aria-labelledby="close-jobs-title" data-testid="close-jobs-dialog">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Job openings</div>
      <h2 id="close-jobs-title">{{ heading }}</h2>
      <p class="hint" data-testid="close-jobs-question">{{ question }}</p>

      <label v-if="offerWithdraw" class="switch">
        <input v-model="withdraw" type="checkbox" data-testid="close-jobs-withdraw" />
        <span>
          Also withdraw the {{ selection.inPlay }} candidate{{ selection.inPlay === 1 ? '' : 's' }} still in play.
          <small>They stop counting as active and the reason lands on each application.</small>
        </span>
      </label>

      <p v-if="selection.inPlay > 0 && !selection.mayWithdraw" class="blocked" data-testid="close-jobs-blocked">
        You cannot move candidates in {{ selection.withdrawBlockedBy }}, so the
        {{ selection.inPlay }} still in play stay there. Close the openings here and withdraw them from their own pages,
        or ask for “Record interview feedback” in that company.
      </p>

      <div class="field">
        <label for="close-jobs-reason">Reason{{ withdrawing ? '' : ' (optional)' }}</label>
        <textarea
          id="close-jobs-reason"
          v-model="reason"
          rows="3"
          maxlength="2000"
          data-testid="close-jobs-reason"
          placeholder="Headcount withdrawn for the year."
        ></textarea>
      </div>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button danger" type="submit" :disabled="nothingToDo" data-testid="close-jobs-confirm">
          {{ withdrawing ? 'Close and withdraw' : 'Close' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.close-dialog {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(470px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.close-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 12px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.switch {
  display: flex;
  gap: 10px;
  align-items: flex-start;
  font-size: 12px;
  line-height: 1.5;
  padding: 12px 13px;
  border: 1px solid var(--line);
  border-radius: 10px;
  margin-bottom: 16px;
}
.switch input { margin-top: 2px; }
.switch small { display: block; color: var(--muted); font-size: 11px; margin-top: 3px; }
.blocked {
  font-size: 11px;
  line-height: 1.6;
  color: var(--ink);
  background: #fbf6ea;
  border: 1px solid #e8dcc0;
  border-radius: 10px;
  padding: 11px 13px;
  margin-bottom: 16px;
}
.field label { display: block; font-size: 11px; color: var(--muted); margin-bottom: 5px; }
.field textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 11px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.danger { background: var(--red); border-color: var(--red); }
.danger:hover:not(:disabled) { background: #8f3838; }
</style>
