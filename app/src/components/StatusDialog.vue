<script setup lang="ts">
import { computed, ref } from 'vue'
import type { SubStatusRow } from '@/lib/hiringLabels'
import { setApplicationStatus } from '@/lib/applicationStatus'
import { contactHint, pickableStatusGroups, statusEventTitle } from '@/lib/stageStatuses'

/**
 * Set the status of one application or many (plan 068; plan 054 began it as
 * "Log outreach"). Every live status is offered, grouped by stage, and the
 * status carries its stage: picking one moves the applications there
 * (plan 075). set_application_status writes one event per application plus
 * the status — all or nothing — decides who may set what, and refuses a
 * closed or hired application; its refusals are shown as it phrases them.
 */

export type OutreachApplication = {
  id: string
  full_name: string
  stage_key: string
  sub_status_key: string | null
}

const NOTE_MAX = 2000

const props = defineProps<{ applications: OutreachApplication[]; rows: SubStatusRow[] }>()
const emit = defineEmits<{ logged: [count: number] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const subStatusKey = ref('')
const note = ref('')
const busy = ref(false)
const error = ref<string | null>(null)

const groups = computed(() => pickableStatusGroups(props.rows))
const stages = computed(() => [...new Set(props.applications.map((a) => a.stage_key))])
const eyebrow = computed(() => statusEventTitle(stages.value.length === 1 ? (stages.value[0] ?? '') : ''))
const title = computed(() => {
  const [first] = props.applications
  return props.applications.length === 1 && first
    ? `Set the status for ${first.full_name}.`
    : `Set the status for ${props.applications.length} applications.`
})
const warning = computed(() => contactHint(subStatusKey.value))
const canSave = computed(() => !busy.value && groups.value.length > 0 && props.applications.length > 0)

function open(): void {
  subStatusKey.value = ''
  note.value = ''
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

async function submit(): Promise<void> {
  error.value = null
  const ids = props.applications.map((a) => a.id)
  if (!ids.length) {
    error.value = 'Pick at least one application.'
    return
  }
  if (!subStatusKey.value) {
    error.value = 'Pick a status.'
    return
  }
  busy.value = true
  const result = await setApplicationStatus(ids, subStatusKey.value, note.value)
  busy.value = false
  if (result.error) {
    error.value = result.error
    return
  }
  dialog.value?.close()
  emit('logged', result.set)
}
</script>

<template>
  <dialog ref="dialog" class="outreach" aria-labelledby="outreach-title" data-testid="outreach-dialog">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">{{ eyebrow }}</div>
      <h2 id="outreach-title">{{ title }}</h2>
      <p class="hint">One entry in each timeline. The status moves the application to its stage.</p>

      <p v-if="!groups.length" class="error-note" role="alert" data-testid="outreach-empty">
        No statuses yet. An admin adds them under Hiring → Labels.
      </p>
      <template v-else>
        <fieldset class="options" :disabled="busy">
          <legend class="legend">Status</legend>
          <div v-for="g in groups" :key="g.stageKey" class="group">
            <div class="group-label">{{ g.stageLabel }}</div>
            <label v-for="s in g.options" :key="s.key" class="option">
              <input v-model="subStatusKey" type="radio" name="outreach-sub" :value="s.key" :data-testid="`outreach-sub-${s.key}`" />
              <span>{{ s.label }}</span>
            </label>
          </div>
        </fieldset>
        <p v-if="warning" class="hint warning" role="note" data-testid="outreach-contact-hint">{{ warning }}</p>
        <div class="field">
          <label for="outreach-note">What happened? (optional)</label>
          <textarea id="outreach-note" v-model="note" rows="3" :maxlength="NOTE_MAX" data-testid="outreach-note"></textarea>
        </div>
      </template>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="!canSave" data-testid="outreach-save">
          {{ busy ? 'Saving…' : 'Save' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.outreach {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(460px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.outreach::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.options { border: 0; padding: 0; margin: 0 0 16px; display: grid; gap: 10px; max-height: 320px; overflow-y: auto; }
.legend { font-size: 12px; font-weight: 600; color: #4d5e57; margin-bottom: 4px; }
.group { display: grid; gap: 8px; }
.group-label { font-size: 11px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; margin-top: 4px; }
.option { display: flex; align-items: center; gap: 9px; font-size: 13px; cursor: pointer; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.warning { color: var(--amber); }
</style>
