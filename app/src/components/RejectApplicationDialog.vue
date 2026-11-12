<script setup lang="ts">
import { computed, ref } from 'vue'
import type { Outcome, SubStatusRow } from '@/lib/hiringLabels'
import { setApplicationStatus } from '@/lib/applicationStatus'
import { emailCandidates } from '@/lib/candidateEmails'
import { contactHint, pickableStatusGroups } from '@/lib/stageStatuses'

/**
 * Reject or withdraw an application (plan 018a). Since plan 075 the status
 * is the reason: Reject offers every live status whose outcome is
 * "rejected", Withdraw those whose outcome is "withdrew", grouped by stage,
 * and picking one moves the application to that status's stage through
 * set_application_status. The application's current stage is listed first. The note is optional and goes into the timeline.
 */
type Mode = 'reject' | 'withdraw'
const OUTCOME_OF: Record<Mode, Outcome> = { reject: 'rejected', withdraw: 'withdrew' }

const props = withDefaults(defineProps<{ rows?: SubStatusRow[] }>(), { rows: () => [] })
const emit = defineEmits<{ decided: [mode: Mode] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const mode = ref<Mode>('reject')
const candidateName = ref('')
const applicationIds = ref<string[]>([])
const statusKey = ref('')
const note = ref('')
const busy = ref(false)
const error = ref<string | null>(null)

const currentStage = ref<string | undefined>(undefined)
const groups = computed(() => pickableStatusGroups(props.rows, OUTCOME_OF[mode.value], currentStage.value))
const warning = computed(() => contactHint(statusKey.value))
// 0102: the candidate hears by email unless HR untick it. The hiring
// manager's own calls (contact in future, do not contact) are not a withdrawal
// by the candidate, so there is nothing to confirm to them.
const emailCandidate = ref(true)
const canEmail = computed(() => {
  const picked = props.rows.find((r) => r.key === statusKey.value)
  return !picked?.hm_only
})

/** `stageKey`: the application's current stage, whose statuses are listed first. */
function open(next: Mode, name: string, ids: string[], stageKey?: string): void {
  mode.value = next
  currentStage.value = stageKey
  candidateName.value = name
  applicationIds.value = ids
  statusKey.value = ''
  note.value = ''
  emailCandidate.value = true
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

async function submit(): Promise<void> {
  error.value = null
  if (!statusKey.value) {
    error.value = mode.value === 'reject' ? 'Pick why the application is rejected.' : 'Pick why the candidate withdrew.'
    return
  }
  busy.value = true
  const result = await setApplicationStatus(applicationIds.value, statusKey.value, note.value)
  if (result.error) {
    busy.value = false
    error.value = result.error
    return
  }
  if (emailCandidate.value && canEmail.value) {
    const sent = await emailCandidates(applicationIds.value, mode.value === 'reject' ? 'rejected' : 'withdrawn')
    if (sent.error) {
      busy.value = false
      error.value = `The status is saved, but the email was not: ${sent.error}`
      emit('decided', mode.value)
      return
    }
  }
  busy.value = false
  dialog.value?.close()
  emit('decided', mode.value)
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
          ? 'The status you pick is the reason. It stays on the application and in its timeline.'
          : 'Recorded so the pipeline and source reports stay honest.' }}
      </p>
      <p v-if="!groups.length" class="error-note" role="alert" data-testid="reject-empty">
        No statuses for this yet. An admin adds them under Hiring → Labels.
      </p>
      <template v-else>
        <fieldset class="options" :disabled="busy">
          <legend class="legend">Status</legend>
          <div v-for="g in groups" :key="g.stageKey" class="group">
            <div class="group-label">{{ g.stageLabel }}</div>
            <label v-for="s in g.options" :key="s.key" class="option">
              <input v-model="statusKey" type="radio" name="reject-status" :value="s.key" :data-testid="`reject-status-${s.key}`" />
              <span>{{ s.label }}</span>
            </label>
          </div>
        </fieldset>
        <p v-if="warning" class="hint warning" role="note" data-testid="reject-contact-hint">{{ warning }}</p>
        <div class="field">
          <label for="reject-reason">Anything to add? (optional)</label>
          <textarea id="reject-reason" v-model="note" rows="4" maxlength="2000" :disabled="busy"></textarea>
        </div>
        <label v-if="canEmail" class="option" data-testid="reject-email">
          <input id="reject-email" v-model="emailCandidate" type="checkbox" :disabled="busy" />
          <span>{{ mode === 'reject' ? 'Email the candidate a polite decline (no reason is given)' : 'Email the candidate a confirmation of the withdrawal' }}</span>
        </label>
      </template>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" :disabled="busy" @click="dialog?.close()">Cancel</button>
        <button class="button" :class="{ danger: mode === 'reject' }" type="submit" :disabled="busy || !groups.length">
          {{ busy ? 'Saving…' : mode === 'reject' ? 'Reject application' : 'Record withdrawal' }}
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
.group { display: grid; gap: 8px; }
.group-label { font-size: 11px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; margin-top: 4px; }
.option { display: flex; align-items: center; gap: 9px; font-size: 13px; cursor: pointer; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.danger { background: var(--red); border-color: var(--red); }
.warning { color: var(--amber); }
.danger:hover { background: #8f3838; }
</style>
