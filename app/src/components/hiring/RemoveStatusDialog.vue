<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import type { SubStatusRow } from '@/lib/hiringLabels'
import { removalNotice, removalPlan, type RemovalResult, type StatusUsage } from '@/lib/statusRemoval'

/**
 * Remove a hiring status from the Labels page (plan 069). Asks the database
 * how many applications carry it and how many timeline entries name it, then
 * — when some still carry it — where they go: another live status of the
 * same stage, or nowhere (they keep it, and it stops being offered).
 * `remove_sub_status` does the rest and decides delete or retire; its
 * refusals are shown as it phrases them.
 */

const emit = defineEmits<{ removed: [notice: string] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const row = ref<SubStatusRow | null>(null)
const targets = ref<SubStatusRow[]>([])
const usage = ref<StatusUsage | null>(null)
const choice = ref<'move' | 'leave'>('move')
const moveTo = ref('')
const busy = ref(false)
const error = ref<string | null>(null)

const plan = computed(() => (row.value && usage.value ? removalPlan(usage.value, row.value.label) : null))
const canConfirm = computed(
  () => !busy.value && plan.value !== null && (plan.value.mode !== 'move' || choice.value === 'leave' || Boolean(moveTo.value)),
)

async function open(status: SubStatusRow, others: SubStatusRow[]): Promise<void> {
  row.value = status
  targets.value = others
  usage.value = null
  choice.value = others.length ? 'move' : 'leave'
  moveTo.value = ''
  error.value = null
  dialog.value?.showModal()
  const { data, error: err } = await supabase.rpc('sub_status_usage', { p_key: status.key })
  if (err) {
    error.value = err.message
    return
  }
  usage.value = data as StatusUsage
}
defineExpose({ open })

async function confirm(): Promise<void> {
  if (!row.value || !plan.value) return
  const moving = plan.value.mode === 'move' && choice.value === 'move'
  if (moving && !moveTo.value) {
    error.value = 'Pick where its applications go.'
    return
  }
  busy.value = true
  error.value = null
  const { data, error: err } = await supabase.rpc('remove_sub_status', {
    p_key: row.value.key,
    ...(moving ? { p_move_to: moveTo.value } : {}),
  })
  busy.value = false
  if (err) {
    error.value = err.message
    return
  }
  const target = moving ? (targets.value.find((t) => t.key === moveTo.value)?.label ?? null) : null
  dialog.value?.close()
  emit('removed', removalNotice(data as RemovalResult, row.value.label, target))
}
</script>

<template>
  <dialog ref="dialog" class="remove-status" aria-labelledby="remove-status-title" data-testid="remove-status-dialog">
    <form class="body" novalidate @submit.prevent="confirm">
      <div class="eyebrow">Remove a status</div>
      <h2 id="remove-status-title">Remove “{{ row?.label }}”?</h2>

      <p v-if="!plan && !error" class="hint">Checking where it is used…</p>
      <template v-if="plan">
        <p class="summary" data-testid="remove-status-summary">{{ plan.summary }}</p>
        <fieldset v-if="plan.mode === 'move'" class="options" :disabled="busy">
          <label class="option">
            <input v-model="choice" type="radio" value="move" :disabled="!targets.length" data-testid="remove-status-move" />
            <span>Move them to</span>
            <select v-model="moveTo" :disabled="choice !== 'move' || !targets.length" aria-label="Move them to" data-testid="remove-status-target">
              <option value="">Choose a status</option>
              <option v-for="t in targets" :key="t.key" :value="t.key">{{ t.label }}</option>
            </select>
          </label>
          <p v-if="!targets.length" class="hint">This stage has no other status yet. Add one first, or leave them.</p>
          <label class="option">
            <input v-model="choice" type="radio" value="leave" data-testid="remove-status-leave" />
            <span>Leave them as they are, and stop offering it</span>
          </label>
          <router-link
            class="review"
            :to="{ name: 'hiring', query: { tab: 'applicants', stage: row?.stage_key, status: row?.key } }"
            data-testid="remove-status-review"
            @click="dialog?.close()"
          >
            Review them first
          </router-link>
        </fieldset>
        <p v-if="plan.mode === 'move' && choice === 'move'" class="hint">
          Each application's timeline records the move. It does not count as activity on the candidate.
        </p>
      </template>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" :disabled="busy" @click="dialog?.close()">Cancel</button>
        <button class="button danger" type="submit" :disabled="!canConfirm" data-testid="remove-status-confirm">
          {{ busy ? 'Removing…' : (plan?.confirmLabel ?? 'Remove status') }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.remove-status {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(480px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.remove-status::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.summary { font-size: 13px; line-height: 1.6; margin: 0 0 14px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin: 0 0 12px; }
.options { border: 0; padding: 0; margin: 0 0 12px; display: grid; gap: 10px; }
.option { display: flex; align-items: center; gap: 9px; font-size: 13px; cursor: pointer; flex-wrap: wrap; }
.option select { border: 1px solid var(--line); background: #fff; padding: 6px 8px; font-size: 12px; color: var(--ink); min-width: 0; max-width: 100%; }
.review { font-size: 12px; color: var(--green); }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.danger { background: var(--red); border-color: var(--red); }
.danger:hover { background: #8f3838; }
</style>
