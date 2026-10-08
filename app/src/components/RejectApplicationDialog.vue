<script setup lang="ts">
import { computed, ref } from 'vue'
import type { SubStatus } from '@/lib/outreach'
import { contactHint } from '@/lib/stageStatuses'

/**
 * Reject or withdraw an application with a recorded reason (plan 018a). Since
 * plan 068 the reason starts from a status of the stage arrived at — Rejected
 * or Withdrawn, the list HR keeps under Hiring → Labels — and the note adds
 * to it. The status is required while the stage has any; the note is
 * required only when it has none, as before. Both are stored on the
 * application and in the timeline, and later feed the candidate-facing message.
 */
type Mode = 'reject' | 'withdraw'
const STAGE_OF: Record<Mode, string> = { reject: 'rejected', withdraw: 'withdrawn' }
const NOTE_MIN = 5

const props = withDefaults(defineProps<{ subStatuses?: SubStatus[] }>(), { subStatuses: () => [] })
const emit = defineEmits<{ confirmed: [payload: { mode: Mode; note: string; status: SubStatus | null }] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const mode = ref<Mode>('reject')
const candidateName = ref('')
const statusKey = ref('')
const reason = ref('')
const error = ref<string | null>(null)

const options = computed(() =>
  props.subStatuses.filter((s) => s.stage_key === STAGE_OF[mode.value]).sort((a, b) => a.sort_order - b.sort_order),
)

const warning = computed(() => contactHint(statusKey.value))

function open(next: Mode, name: string): void {
  mode.value = next
  candidateName.value = name
  statusKey.value = ''
  reason.value = ''
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

function submit(): void {
  const trimmed = reason.value.trim()
  const status = options.value.find((s) => s.key === statusKey.value) ?? null
  if (options.value.length && !status) {
    error.value = mode.value === 'reject' ? 'Pick why the application is rejected.' : 'Pick why the candidate withdrew.'
    return
  }
  if (!status && trimmed.length < NOTE_MIN) {
    error.value = mode.value === 'reject' ? 'Give the reason for rejecting — it is recorded.' : 'Give the reason the candidate withdrew.'
    return
  }
  dialog.value?.close()
  emit('confirmed', { mode: mode.value, note: trimmed, status })
}
</script>

<template>
  <dialog ref="dialog" class="reject-dialog" aria-labelledby="reject-title" data-testid="reject-dialog">
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
      <fieldset v-if="options.length" class="options">
        <legend class="legend">Status</legend>
        <label v-for="s in options" :key="s.key" class="option">
          <input v-model="statusKey" type="radio" name="reject-status" :value="s.key" :data-testid="`reject-status-${s.key}`" />
          <span>{{ s.label }}</span>
        </label>
      </fieldset>
      <p v-if="warning" class="hint warning" role="note" data-testid="reject-contact-hint">{{ warning }}</p>
      <div class="field">
        <label for="reject-reason">{{ options.length ? 'Anything to add? (optional)' : 'Reason' }}</label>
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
.options { border: 0; padding: 0; margin: 0 0 14px; display: grid; gap: 9px; max-height: 260px; overflow-y: auto; }
.legend { font-size: 12px; font-weight: 600; color: #4d5e57; margin-bottom: 4px; }
.option { display: flex; align-items: center; gap: 9px; font-size: 13px; cursor: pointer; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.danger { background: var(--red); border-color: var(--red); }
.warning { color: var(--amber); }
.danger:hover { background: #8f3838; }
</style>
