<script setup lang="ts">
import { computed, ref } from 'vue'
import type { SubStatus } from '@/lib/outreach'

/**
 * Who acts next on an application, and — at Screening — what the screening
 * decided. The page turns the outcome into a status (plan 075): Proceed sets
 * Interview's first open status, Reject the Rejected status picked here,
 * Follow up leaves the status alone.
 */
export type HandoffOutcome = 'interview' | 'screening' | 'rejected'
/** `outcome` is null for an assignment edit; `subStatusKey` is the Rejected status picked, else ''. */
export type HandoffPayload = {
  outcome: HandoffOutcome | null
  ownerId: string
  nextAction: string
  nextActionDue: string
  note: string
  subStatusKey: string
}
type Mode = 'assign' | 'outcome'

const props = withDefaults(defineProps<{
  people: { id: string; full_name: string }[]
  save: (payload: HandoffPayload) => Promise<void>
  rejectStatuses?: SubStatus[]
}>(), { rejectStatuses: () => [] })
const dialog = ref<HTMLDialogElement | null>(null)
const mode = ref<Mode>('assign')
const outcome = ref<HandoffOutcome>('interview')
const form = ref({ ownerId: '', nextAction: '', nextActionDue: '', note: '' })
const rejectStatus = ref('')
const busy = ref(false)
const error = ref('')
const title = computed(() => (mode.value === 'outcome' ? 'Record screening outcome' : 'Edit assignment'))
const rejecting = computed(() => mode.value === 'outcome' && outcome.value === 'rejected')

function open(next: Mode, assignment: { ownerId: string; nextAction: string; nextActionDue: string }): void {
  mode.value = next
  outcome.value = 'interview'
  rejectStatus.value = ''
  // A new step gets its own due date; only an assignment edit keeps the current one.
  form.value = {
    ...assignment,
    note: '',
    nextAction: next === 'outcome' ? 'Schedule interview' : assignment.nextAction,
    nextActionDue: next === 'assign' ? assignment.nextActionDue : '',
  }
  error.value = ''
  dialog.value?.showModal()
}
defineExpose({ open })

function changeOutcome(): void {
  form.value = { ...form.value, nextAction: outcome.value === 'interview' ? 'Schedule interview' : outcome.value === 'screening' ? 'Follow up on screening' : '', nextActionDue: '' }
}

function problem(): string {
  if (!rejecting.value && (!form.value.ownerId || !form.value.nextAction.trim() || !form.value.nextActionDue)) {
    return 'Choose an owner, a next action, and a due date.'
  }
  if (rejecting.value && !props.rejectStatuses.length) return 'No Rejected statuses yet. An admin adds them under Hiring → Labels.'
  if (rejecting.value && !rejectStatus.value) return 'Pick why the application is rejected.'
  // A rejection names its status, so its note may stay empty.
  if (mode.value === 'outcome' && !rejecting.value && form.value.note.trim().length < 5) {
    return 'Record a short screening outcome.'
  }
  return ''
}

async function submit(): Promise<void> {
  error.value = problem()
  if (error.value) return
  busy.value = true
  try {
    await props.save({
      ...form.value,
      nextAction: form.value.nextAction.trim(),
      note: form.value.note.trim(),
      outcome: mode.value === 'outcome' ? outcome.value : null,
      subStatusKey: rejecting.value ? rejectStatus.value : '',
    })
    dialog.value?.close()
  } catch (e) { error.value = e instanceof Error ? e.message : 'Could not save. Your changes are still here.' }
  finally { busy.value = false }
}
</script>

<template>
  <dialog ref="dialog" class="handoff-dialog" aria-labelledby="handoff-title" @cancel="busy && $event.preventDefault()">
    <form novalidate @submit.prevent="submit">
      <div class="eyebrow">Candidate handoff</div>
      <h2 id="handoff-title">{{ title }}</h2>
      <p>{{ mode === 'outcome' ? 'Record what you learned, then choose the next step. Responses entered on the page will also be saved.' : 'Choose who acts next and by when. We will attempt to email the assigned colleague.' }}</p>
      <fieldset :disabled="busy">
        <template v-if="mode === 'outcome'">
          <div class="field"><label for="handoff-outcome">Outcome</label><select id="handoff-outcome" v-model="outcome" @change="changeOutcome"><option value="interview">Proceed to interview</option><option value="screening">Follow up</option><option value="rejected">Reject</option></select></div>
          <div v-if="rejecting" class="field">
            <label for="handoff-reject-status">Status</label>
            <select id="handoff-reject-status" v-model="rejectStatus" data-testid="handoff-reject-status">
              <option value="">Choose why</option>
              <option v-for="s in rejectStatuses" :key="s.key" :value="s.key">{{ s.label }}</option>
            </select>
          </div>
          <div class="field"><label for="handoff-note">{{ rejecting ? 'Anything to add? (optional)' : 'Screening outcome' }}</label><textarea id="handoff-note" v-model="form.note" rows="4" maxlength="2000"></textarea></div>
        </template>
        <template v-if="!rejecting">
          <div class="field"><label for="handoff-owner">Owner</label><select id="handoff-owner" v-model="form.ownerId"><option value="">Choose an owner</option><option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option></select></div>
          <div class="field"><label for="handoff-action">Next action</label><input id="handoff-action" v-model="form.nextAction" maxlength="200" /></div>
          <div class="field"><label for="handoff-due">Due date for this action</label><input id="handoff-due" v-model="form.nextActionDue" type="date" /></div>
        </template>
      </fieldset>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions"><button class="button secondary" type="button" :disabled="busy" @click="dialog?.close()">Cancel</button><button class="button" type="submit" :disabled="busy">{{ busy ? 'Saving…' : mode === 'outcome' ? 'Save outcome and next step' : 'Save assignment' }}</button></div>
    </form>
  </dialog>
</template>

<style scoped>
.handoff-dialog { border: 0; border-radius: 15px; padding: 26px 28px; width: min(520px, calc(100vw - 36px)); max-height: 90vh; overflow: auto; color: var(--ink); box-shadow: 0 25px 100px #122f3038; }
.handoff-dialog::backdrop { background: #18372d70; }
fieldset { border: 0; padding: 0; margin: 0; }
h2 { margin: 10px 0; }
p { font-size: 12px; line-height: 1.6; color: var(--muted); }
textarea { width: 100%; padding: 10px; border: 1px solid var(--line); font: inherit; }
.actions { display: flex; justify-content: flex-end; gap: 9px; margin-top: 16px; }
</style>
