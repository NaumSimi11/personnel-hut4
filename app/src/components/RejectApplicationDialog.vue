<script setup lang="ts">
import { ref } from 'vue'

/**
 * Reject or withdraw an application with a recorded reason (plan 018a). The
 * reason is required: it is stored on the application and in the timeline,
 * and later feeds the candidate-facing message.
 */
type Mode = 'reject' | 'withdraw'

const emit = defineEmits<{ confirmed: [payload: { mode: Mode; reason: string }] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const mode = ref<Mode>('reject')
const candidateName = ref('')
const reason = ref('')
const error = ref<string | null>(null)

function open(next: Mode, name: string): void {
  mode.value = next
  candidateName.value = name
  reason.value = ''
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

function submit(): void {
  const trimmed = reason.value.trim()
  if (trimmed.length < 5) {
    error.value = mode.value === 'reject' ? 'Give the reason for rejecting — it is recorded.' : 'Give the reason the candidate withdrew.'
    return
  }
  dialog.value?.close()
  emit('confirmed', { mode: mode.value, reason: trimmed })
}
</script>

<template>
  <dialog ref="dialog" class="reject-dialog" aria-labelledby="reject-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">{{ mode === 'reject' ? 'Decision' : 'Candidate withdrew' }}</div>
      <h2 id="reject-title">
        {{ mode === 'reject' ? `Reject ${candidateName || 'this application'}.` : `${candidateName || 'The candidate'} withdrew.` }}
      </h2>
      <p class="hint">
        {{ mode === 'reject'
          ? 'The reason stays on the application and in its timeline. Write it as you would want it read back to you.'
          : 'Recorded so the pipeline and source reports stay honest.' }}
      </p>
      <div class="field">
        <label for="reject-reason">Reason</label>
        <textarea id="reject-reason" v-model="reason" rows="4" maxlength="1000"></textarea>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" :class="{ danger: mode === 'reject' }" type="submit">
          {{ mode === 'reject' ? 'Reject application' : 'Record withdrawal' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.reject-dialog {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(460px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.reject-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
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
.danger:hover { background: #8f3838; }
</style>
