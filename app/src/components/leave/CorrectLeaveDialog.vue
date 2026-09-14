<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { correctionSummary, friendlyLeaveError, shortDate, workingDaysInRange, type CorrectionDay } from '@/lib/leave'

/**
 * Correct approved leave (plan 041, after the old HR's Manager desk): pick
 * the dates, set each working day's kind, read what it does to the balance,
 * say why. correct_leave rewrites the record — splitting it when the kinds
 * differ — and takes or returns the days.
 */
export type CorrectionTarget = {
  id: string
  person_id: string
  company_id: string
  leave_type_key: string
  deducts_balance: boolean
  start_date: string
  end_date: string
  working_days: number
  note: string | null
  person?: { full_name: string } | null
}

const emit = defineEmits<{ corrected: [result: { workingDays: number; split: number }] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const target = ref<CorrectionTarget | null>(null)
const types = ref<{ key: string; label: string; deducts_balance: boolean }[]>([])
const holidays = ref<string[]>([])
const closures = ref<string[]>([])
const start = ref('')
const end = ref('')
const note = ref('')
const kinds = ref<Record<string, string>>({})
const error = ref<string | null>(null)
const busy = ref(false)

const deductsByType = computed(() => Object.fromEntries(types.value.map((t) => [t.key, t.deducts_balance])))
const workingDays = computed(() => workingDaysInRange(start.value, end.value, holidays.value, closures.value))
const days = computed<CorrectionDay[]>(() =>
  workingDays.value.map((date) => ({ date, leave_type_key: kinds.value[date] ?? target.value?.leave_type_key ?? 'annual' })),
)
const firstName = computed(() => target.value?.person?.full_name.split(' ')[0] ?? 'the person')
const summary = computed(() =>
  target.value ? correctionSummary(days.value, target.value.working_days, target.value.deducts_balance, deductsByType.value, firstName.value) : '',
)
const unchanged = computed(
  () =>
    !!target.value &&
    start.value === target.value.start_date &&
    end.value === target.value.end_date &&
    days.value.every((d) => d.leave_type_key === target.value!.leave_type_key),
)
function weekday(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { weekday: 'short', timeZone: 'UTC' })
}
function dayNumber(iso: string): number {
  return Number(iso.slice(8, 10))
}

async function open(t: CorrectionTarget, countryCode: string | null): Promise<void> {
  target.value = t
  start.value = t.start_date
  end.value = t.end_date
  note.value = ''
  kinds.value = {}
  error.value = null
  dialog.value?.showModal()
  // Days off for a generous window around the leave, so extending it still counts right.
  const from = new Date(`${t.start_date}T00:00:00Z`)
  from.setUTCDate(from.getUTCDate() - 62)
  const to = new Date(`${t.end_date}T00:00:00Z`)
  to.setUTCDate(to.getUTCDate() + 62)
  const [typesRes, holRes, cloRes] = await Promise.all([
    supabase.from('leave_types').select('key, label, deducts_balance').eq('is_active', true).order('sort_order'),
    countryCode
      ? supabase.from('public_holidays').select('date').eq('country_code', countryCode).gte('date', from.toISOString().slice(0, 10)).lte('date', to.toISOString().slice(0, 10))
      : Promise.resolve({ data: [] as { date: string }[], error: null }),
    supabase.from('company_closures').select('date').eq('company_id', t.company_id).gte('date', from.toISOString().slice(0, 10)).lte('date', to.toISOString().slice(0, 10)),
  ])
  types.value = typesRes.data ?? []
  holidays.value = (holRes.data ?? []).map((h) => h.date)
  closures.value = (cloRes.data ?? []).map((c) => c.date)
}
defineExpose({ open })

watch(start, (s) => {
  if (end.value < s) end.value = s
})

function setKind(date: string, key: string): void {
  kinds.value = { ...kinds.value, [date]: key }
}

async function submit(): Promise<void> {
  if (!target.value) return
  error.value = null
  if (!days.value.length) {
    error.value = 'Choose at least one working day.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('correct_leave', {
    p_request_id: target.value.id,
    p_days: days.value.map((d) => ({ ...d })),
    p_note: note.value.trim() || undefined,
  })
  busy.value = false
  if (err) {
    error.value = friendlyLeaveError(err.message)
    console.error('Leave correction failed:', err.message)
    return
  }
  const result = data as { working_days?: number; split_request_ids?: string[] } | null
  dialog.value?.close()
  emit('corrected', { workingDays: Number(result?.working_days ?? 0), split: result?.split_request_ids?.length ?? 0 })
}
</script>

<template>
  <dialog ref="dialog" class="correct-dialog" aria-labelledby="correct-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Correction</div>
      <h2 id="correct-title">Correct {{ target?.person?.full_name ?? 'this' }}’s leave</h2>
      <p class="hint">
        Was {{ target ? `${shortDate(target.start_date)} → ${shortDate(target.end_date)} · ${target.working_days} working ${target.working_days === 1 ? 'day' : 'days'} · ${target.leave_type_key.replace('_', ' ')}` : '' }}.
        Extra days come off the balance, dropped days go back; a day of another kind splits the record.
      </p>
      <div class="grid">
        <div class="field">
          <label for="cl-start">From</label>
          <input id="cl-start" v-model="start" type="date" required />
        </div>
        <div class="field">
          <label for="cl-end">To</label>
          <input id="cl-end" v-model="end" type="date" :min="start" required />
        </div>
      </div>
      <div v-if="workingDays.length" class="days" data-testid="correction-days">
        <div v-for="d in days" :key="d.date" class="day-pick">
          <span class="dow">{{ weekday(d.date) }}</span>
          <b>{{ dayNumber(d.date) }}</b>
          <select :aria-label="`Kind of leave on ${d.date}`" :value="d.leave_type_key" @change="setKind(d.date, ($event.target as HTMLSelectElement).value)">
            <option v-for="t in types" :key="t.key" :value="t.key">{{ t.label }}</option>
          </select>
        </div>
      </div>
      <p v-else class="empty-days">No working days between those dates.</p>
      <output class="summary" data-testid="correction-summary">{{ summary }}</output>
      <div class="field">
        <label for="cl-note">Note</label>
        <input id="cl-note" v-model="note" maxlength="500" placeholder="Why the record changes — kept with the correction" />
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Leave it as it is</button>
        <button class="button" type="submit" :disabled="busy || unchanged || !days.length">{{ busy ? 'Saving…' : 'Save the correction' }}</button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.correct-dialog { border: 0; border-radius: 15px; padding: 0; width: min(640px, calc(100vw - 36px)); color: var(--ink); }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 8px; }
.hint { font-size: 12px; color: var(--muted); line-height: 1.6; margin: 0 0 16px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.days { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 14px; }
.day-pick { display: grid; justify-items: center; gap: 4px; padding: 8px 6px 6px; border: 1px solid var(--line); border-radius: 10px; background: #f7f9f5; min-width: 78px; }
.day-pick .dow { font-size: 10px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); font-weight: 650; }
.day-pick b { font-size: 20px; font-weight: 700; letter-spacing: -0.02em; line-height: 1; }
.day-pick select { font-size: 11px; padding: 4px 6px; border: 1px solid var(--line-strong); background: #fff; border-radius: 6px; max-width: 100%; }
.empty-days { font-size: 12px; color: var(--amber); margin: 0 0 14px; }
.summary { display: block; padding: 11px 14px; border-radius: 9px; background: #f1f4ef; font-size: 12.5px; margin-bottom: 16px; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 8px; }
</style>
