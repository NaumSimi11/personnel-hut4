<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { useDialogStore } from '@/stores/dialogs'
import { validateReason, type ConfirmRequest, type ReasonRequest } from '@/lib/dialogs'

/**
 * Renders the current question from the dialog store (plan 046): a
 * confirmation, or a reason with an optional number. Mounted once in
 * App.vue. Escape, Cancel and any other close answer "no" / null, so a
 * question is never left hanging and the queue never wedges.
 */
const store = useDialogStore()
const dialog = ref<HTMLDialogElement | null>(null)
const reason = ref('')
const value = ref('')
const error = ref<string | null>(null)

const request = computed(() => store.current?.request ?? null)
const asReason = computed<ReasonRequest | null>(() => (request.value?.kind === 'reason' ? request.value : null))
const asConfirm = computed<ConfirmRequest | null>(() => (request.value?.kind === 'confirm' ? request.value : null))
const confirmLabel = computed(() => request.value?.confirmLabel ?? (asReason.value ? 'Save' : 'Confirm'))

watch(
  () => store.current?.id,
  async (id) => {
    error.value = null
    if (!id) {
      if (dialog.value?.open) dialog.value.close()
      return
    }
    reason.value = asReason.value?.initial ?? ''
    value.value = asReason.value?.value?.initial !== undefined ? String(asReason.value.value.initial) : ''
    await nextTick()
    // showModal() runs the dialog focusing steps: the first autofocus control.
    if (dialog.value && !dialog.value.open) dialog.value.showModal()
  },
)

function cancel(): void {
  store.settle(asReason.value ? null : false)
}

/** Closed by any route the cancel event did not cover (a second Escape, for one). */
function onClosed(): void {
  if (store.current) cancel()
}

function submit(): void {
  if (asConfirm.value) {
    store.settle(true)
    return
  }
  if (!asReason.value) return
  const number = value.value === '' ? null : Number(value.value)
  const problem = validateReason(asReason.value, reason.value, number)
  if (problem) {
    error.value = problem
    return
  }
  store.settle({ reason: reason.value.trim(), value: asReason.value.value ? number : null })
}
</script>

<template>
  <dialog
    ref="dialog"
    class="app-dialog"
    data-testid="reason-dialog"
    aria-labelledby="app-dialog-title"
    @cancel.prevent="cancel"
    @close="onClosed"
  >
    <form v-if="request" class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">{{ request.eyebrow ?? (asReason ? 'Reason' : 'Please confirm') }}</div>
      <h2 id="app-dialog-title">{{ request.title }}</h2>
      <p v-if="request.hint" class="hint">{{ request.hint }}</p>
      <template v-if="asReason">
        <div v-if="asReason.value" class="field">
          <label for="dialog-value">{{ asReason.value.label }}</label>
          <input id="dialog-value" v-model="value" type="number" :min="asReason.value.min" step="1" inputmode="numeric" autofocus />
        </div>
        <div class="field">
          <label for="dialog-reason">{{ asReason.label ?? 'Reason' }}<span v-if="asReason.required === false" class="optional"> (optional)</span></label>
          <textarea id="dialog-reason" v-model="reason" rows="3" maxlength="1000" :autofocus="!asReason.value"></textarea>
        </div>
      </template>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" data-testid="dialog-cancel" @click="cancel">
          {{ asConfirm?.cancelLabel ?? 'Cancel' }}
        </button>
        <button class="button" :class="{ danger: request.danger }" type="submit" data-testid="dialog-confirm" :autofocus="!!asConfirm">
          {{ confirmLabel }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.app-dialog {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(440px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.app-dialog::backdrop { background: #18372d70; }
.body { padding: 24px 26px; }
h2 { font-size: 18px; margin: 10px 0 8px; line-height: 1.35; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 14px; }
.optional { font-weight: 400; color: var(--muted); }
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
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 12px; }
.danger { background: var(--red); border-color: var(--red); }
.danger:hover { background: #8f3838; }
</style>
