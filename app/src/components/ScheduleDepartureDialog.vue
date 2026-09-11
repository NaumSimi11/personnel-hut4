<script setup lang="ts">
import { ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { REASON_MAX, departureInput, friendlyDepartureError } from '@/lib/departure'

/**
 * Schedule a departure for one employment period (plan 016). Records the
 * employment end date, the last working date and an optional restricted
 * reason, and launches the offboarding plan — all in one database call
 * (`schedule_departure`, migration 0010). The person stays active: becoming
 * Former is a separate, explicit act.
 */

export type DeparturePeriod = {
  id: string
  job_title: string
  start_date: string
  company: { name: string } | null
}

const emit = defineEmits<{ scheduled: [result: { planId: string; alreadyScheduled: boolean }] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const period = ref<DeparturePeriod | null>(null)
const personName = ref('')
const form = ref({ endDate: '', lastWorkingDate: '', reason: '' })
const error = ref<string | null>(null)
const busy = ref(false)

function open(target: DeparturePeriod, name: string): void {
  period.value = target
  personName.value = name
  form.value = { endDate: '', lastWorkingDate: '', reason: '' }
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

async function submit(): Promise<void> {
  if (!period.value) return
  error.value = null
  const parsed = departureInput(period.value.start_date).safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('schedule_departure', {
    p_employment_period_id: period.value.id,
    p_end_date: parsed.data.endDate,
    p_last_working_date: parsed.data.lastWorkingDate,
    p_reason: parsed.data.reason || undefined,
  })
  busy.value = false
  if (err) {
    error.value = friendlyDepartureError(err.message)
    return
  }
  const result = data as { plan_id: string; already_scheduled: boolean }
  dialog.value?.close()
  emit('scheduled', { planId: result.plan_id, alreadyScheduled: result.already_scheduled })
}
</script>

<template>
  <dialog ref="dialog" class="departure-dialog" aria-labelledby="departure-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Offboarding</div>
      <h2 id="departure-title">Schedule {{ personName || 'this person' }}'s departure.</h2>
      <p class="hint">
        {{ period?.job_title }} · {{ period?.company?.name }}. This records the dates and starts the
        offboarding plan. They stay active until you mark them as former.
      </p>
      <div class="grid">
        <div class="field">
          <label for="dep-end">Employment end date</label>
          <input id="dep-end" v-model="form.endDate" type="date" required :min="period?.start_date" />
        </div>
        <div class="field">
          <label for="dep-last">Last working date</label>
          <input id="dep-last" v-model="form.lastWorkingDate" type="date" :max="form.endDate || undefined" />
          <small class="field-hint">Leave empty if it is the end date.</small>
        </div>
      </div>
      <div class="field">
        <label for="dep-reason">Reason (restricted)</label>
        <textarea id="dep-reason" v-model="form.reason" rows="3" :maxlength="REASON_MAX"></textarea>
        <small class="field-hint">
          Visible only to people who can start offboarding or view private details — never to the
          person or plain directory viewers.
        </small>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy">
          {{ busy ? 'Scheduling…' : 'Schedule departure' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.departure-dialog {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(480px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.departure-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.field textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 11px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  resize: vertical;
}
.field-hint { display: block; font-size: 10px; color: var(--muted); line-height: 1.5; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
