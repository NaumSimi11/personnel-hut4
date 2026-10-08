<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import { stageLabel } from '@/lib/dashboard'
import type { SubStatus } from '@/lib/outreach'
import { contactHint, noStatusesHint, statusEventTitle } from '@/lib/stageStatuses'

/**
 * Set the status of one application or many, at any stage (plan 068; plan
 * 054 began it as "Log outreach" at New and Screening). Pick the status of
 * the stage the applications are at, say what happened, and
 * set_application_status writes one event per application plus the status —
 * all or nothing. The RPC decides who may set what, and refuses a retired
 * status; its refusals are shown as it phrases them. Only the empty-selection
 * and empty-key guards live here.
 */

export type OutreachApplication = {
  id: string
  full_name: string
  stage_key: string
  sub_status_key: string | null
}

const NOTE_MAX = 2000

const props = defineProps<{ applications: OutreachApplication[]; subStatuses: SubStatus[] }>()
const emit = defineEmits<{ logged: [count: number] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const subStatusKey = ref('')
const note = ref('')
const busy = ref(false)
const error = ref<string | null>(null)

const stages = computed(() => [...new Set(props.applications.map((a) => a.stage_key))])
const mixed = computed(() => stages.value.length > 1)
const stage = computed(() => (stages.value.length === 1 ? (stages.value[0] ?? '') : ''))
const options = computed(() =>
  props.subStatuses.filter((s) => s.stage_key === stage.value).sort((a, b) => a.sort_order - b.sort_order),
)
const empty = computed(() => Boolean(stage.value) && options.value.length === 0)
const eyebrow = computed(() => statusEventTitle(stage.value))
const title = computed(() => {
  const [first] = props.applications
  return props.applications.length === 1 && first
    ? `Set the status for ${first.full_name}.`
    : `Set the status for ${props.applications.length} applications.`
})
const warning = computed(() => contactHint(subStatusKey.value))
const canSave = computed(() => !busy.value && !mixed.value && !empty.value && props.applications.length > 0)

function open(): void {
  subStatusKey.value = ''
  note.value = ''
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

async function submit(): Promise<void> {
  error.value = null
  const ids = [...new Set(props.applications.map((a) => a.id))]
  if (!ids.length) {
    error.value = 'Pick at least one application.'
    return
  }
  if (!subStatusKey.value) {
    error.value = 'Pick a status.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('set_application_status', {
    p_application_ids: ids,
    p_sub_status_key: subStatusKey.value,
    p_note: note.value.trim(),
  })
  busy.value = false
  if (err) {
    error.value = friendlyRecruitmentError(err.message)
    return
  }
  const set = (data as { set?: number } | null)?.set ?? ids.length
  dialog.value?.close()
  emit('logged', set)
}
</script>

<template>
  <dialog ref="dialog" class="outreach" aria-labelledby="outreach-title" data-testid="outreach-dialog">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">{{ eyebrow }}</div>
      <h2 id="outreach-title">{{ title }}</h2>
      <p class="hint">One entry in each timeline; the status moves with it.</p>

      <p v-if="mixed" class="error-note" role="alert" data-testid="outreach-mixed">Pick applications at the same stage.</p>
      <p v-else-if="empty" class="error-note" role="alert" data-testid="outreach-empty">{{ noStatusesHint(stageLabel(stage)) }}</p>
      <template v-else>
        <fieldset class="options" :disabled="busy">
          <legend class="legend">Status</legend>
          <label v-for="s in options" :key="s.key" class="option">
            <input v-model="subStatusKey" type="radio" name="outreach-sub" :value="s.key" :data-testid="`outreach-sub-${s.key}`" />
            <span>{{ s.label }}</span>
          </label>
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
.option { display: flex; align-items: center; gap: 9px; font-size: 13px; cursor: pointer; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.warning { color: var(--amber); }
</style>
