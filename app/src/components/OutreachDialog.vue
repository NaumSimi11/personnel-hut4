<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import { OUTREACH_BLOCKED, SUB_STATUS_STAGES, type SubStatus } from '@/lib/outreach'

/**
 * Log outreach on one application or many (plan 054): pick the sub-status
 * the conversation is at now, say what happened, and log_outreach writes
 * one `outreach` event per application plus the sub-status — all or
 * nothing. The RPC decides who may log and where; its refusals are shown
 * as it phrases them. Only the empty-selection and empty-key guards live
 * here.
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
const blocked = computed(() => Boolean(stage.value) && !(SUB_STATUS_STAGES as readonly string[]).includes(stage.value))
const options = computed(() =>
  props.subStatuses.filter((s) => s.stage_key === stage.value).sort((a, b) => a.sort_order - b.sort_order),
)
const title = computed(() => {
  const [first] = props.applications
  return props.applications.length === 1 && first
    ? `Log outreach for ${first.full_name}.`
    : `Log outreach for ${props.applications.length} applications.`
})
const canSave = computed(() => !busy.value && !mixed.value && !blocked.value && props.applications.length > 0)

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
    error.value = 'Pick a sub-status.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('log_outreach', {
    p_application_ids: ids,
    p_sub_status_key: subStatusKey.value,
    p_note: note.value.trim(),
  })
  busy.value = false
  if (err) {
    error.value = friendlyRecruitmentError(err.message)
    return
  }
  const logged = (data as { logged?: number } | null)?.logged ?? ids.length
  dialog.value?.close()
  emit('logged', logged)
}
</script>

<template>
  <dialog ref="dialog" class="outreach" aria-labelledby="outreach-title" data-testid="outreach-dialog">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Outreach</div>
      <h2 id="outreach-title">{{ title }}</h2>
      <p class="hint">One entry in each timeline; the sub-status moves with it.</p>

      <p v-if="mixed" class="error-note" role="alert" data-testid="outreach-mixed">Pick applications at the same stage.</p>
      <p v-else-if="blocked" class="error-note" role="alert">{{ OUTREACH_BLOCKED }}</p>
      <template v-else>
        <fieldset class="options" :disabled="busy">
          <legend class="legend">Sub-status</legend>
          <label v-for="s in options" :key="s.key" class="option">
            <input v-model="subStatusKey" type="radio" name="outreach-sub" :value="s.key" :data-testid="`outreach-sub-${s.key}`" />
            <span>{{ s.label }}</span>
          </label>
        </fieldset>
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
.options { border: 0; padding: 0; margin: 0 0 16px; display: grid; gap: 10px; }
.legend { font-size: 12px; font-weight: 600; color: #4d5e57; margin-bottom: 4px; }
.option { display: flex; align-items: center; gap: 9px; font-size: 13px; cursor: pointer; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
