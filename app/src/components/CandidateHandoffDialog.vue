<script setup lang="ts">
import { computed, ref } from 'vue'

export type HandoffPayload = { stage: string; ownerId: string; nextAction: string; nextActionDue: string; note: string }
const props = defineProps<{
  people: { id: string; full_name: string }[]
  save: (payload: HandoffPayload) => Promise<void>
}>()
const dialog = ref<HTMLDialogElement | null>(null)
const mode = ref<'assign' | 'start' | 'outcome'>('assign')
const stage = ref('new')
const outcome = ref('interview')
const form = ref({ ownerId: '', nextAction: '', nextActionDue: '', note: '' })
const busy = ref(false)
const error = ref('')
const title = computed(() => mode.value === 'start' ? 'Start screening' : mode.value === 'outcome' ? 'Record screening outcome' : 'Edit assignment')
const rejecting = computed(() => mode.value === 'outcome' && outcome.value === 'rejected')

function open(next: typeof mode.value, currentStage: string, assignment: { ownerId: string; nextAction: string; nextActionDue: string }): void {
  mode.value = next
  stage.value = currentStage
  outcome.value = 'interview'
  // A new step gets its own due date; only an assignment edit keeps the current one.
  form.value = {
    ...assignment,
    note: '',
    nextAction: next === 'start' ? assignment.nextAction || 'Phone screening' : next === 'outcome' ? 'Schedule interview' : assignment.nextAction,
    nextActionDue: next === 'assign' ? assignment.nextActionDue : '',
  }
  error.value = ''
  dialog.value?.showModal()
}
defineExpose({ open })

function changeOutcome(): void {
  form.value = { ...form.value, nextAction: outcome.value === 'interview' ? 'Schedule interview' : outcome.value === 'screening' ? 'Follow up on screening' : '', nextActionDue: '' }
}

async function submit(): Promise<void> {
  error.value = ''
  if (!rejecting.value && (!form.value.ownerId || !form.value.nextAction.trim() || !form.value.nextActionDue)) {
    error.value = 'Choose an owner, a next action, and a due date.'; return
  }
  if (mode.value === 'outcome' && form.value.note.trim().length < 5) {
    error.value = 'Record a short screening outcome or rejection reason.'; return
  }
  busy.value = true
  try {
    await props.save({ ...form.value, nextAction: form.value.nextAction.trim(), note: form.value.note.trim(), stage: mode.value === 'start' ? 'screening' : mode.value === 'outcome' ? outcome.value : stage.value })
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
          <div class="field"><label for="handoff-note">Screening outcome / reason</label><textarea id="handoff-note" v-model="form.note" rows="4" maxlength="2000"></textarea></div>
        </template>
        <template v-if="!rejecting">
          <div class="field"><label for="handoff-owner">Owner</label><select id="handoff-owner" v-model="form.ownerId"><option value="">Choose an owner</option><option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option></select></div>
          <div class="field"><label for="handoff-action">Next action</label><input id="handoff-action" v-model="form.nextAction" maxlength="200" /></div>
          <div class="field"><label for="handoff-due">Due date for this action</label><input id="handoff-due" v-model="form.nextActionDue" type="date" /></div>
        </template>
      </fieldset>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions"><button class="button secondary" type="button" :disabled="busy" @click="dialog?.close()">Cancel</button><button class="button" type="submit" :disabled="busy">{{ busy ? 'Saving…' : mode === 'outcome' ? 'Save outcome and next step' : mode === 'start' ? 'Start screening' : 'Save assignment' }}</button></div>
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
