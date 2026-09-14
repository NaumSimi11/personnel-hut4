<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { todayDb } from '@/lib/compensation'
import { deliverNotifications } from '@/lib/notificationsApi'
import { balanceAfter, clashesWith, friendlyLeaveError, leaveInput, workingDaysBetween, type ClashRow } from '@/lib/leave'

/**
 * Request leave for oneself, or record it for someone else (plan 036). The
 * working-day preview mirrors app.working_days with the person's calendar
 * (employment location's country, else the company's) and the company's
 * closures; request_leave computes the real number and enforces every rule.
 */

export type LeaveSubject = {
  personId: string
  personName: string
  companyId: string
  companyName: string
  countryCode: string | null
  /** True when an approver records leave for someone else. */
  onBehalf: boolean
}

const emit = defineEmits<{ submitted: [result: { status: string; workingDays: number }] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const subject = ref<LeaveSubject | null>(null)
const types = ref<{ key: string; label: string; deducts_balance: boolean; requires_document: boolean }[]>([])
const offDays = ref<{ holidays: string[]; closures: string[] }>({ holidays: [], closures: [] })
const form = ref({ leaveTypeKey: 'annual', start: '', end: '', note: '', documentsToFollow: false, recordAsApproved: false })
const error = ref<string | null>(null)
const busy = ref(false)
// Ported from Field Notebook: the balance after this request, and who from
// the same department is away on the same days (pending counted) — a
// heads-up, never a block; request_leave decides.
const available = ref<number | null>(null)
const colleagueIds = ref<Set<string>>(new Set())
const teamRows = ref<ClashRow[]>([])
let loadSeq = 0

const selectedType = computed(() => types.value.find((t) => t.key === form.value.leaveTypeKey))
const previewDays = computed(() =>
  workingDaysBetween(form.value.start, form.value.end, offDays.value.holidays, offDays.value.closures),
)
const after = computed(() => (available.value !== null ? balanceAfter({ available: available.value }, previewDays.value, selectedType.value?.deducts_balance ?? false) : null))
const clashes = computed(() =>
  subject.value ? clashesWith(teamRows.value, { start: form.value.start, end: form.value.end, personId: subject.value.personId, colleagueIds: colleagueIds.value }) : [],
)

async function open(s: LeaveSubject): Promise<void> {
  subject.value = s
  error.value = null
  form.value = { leaveTypeKey: 'annual', start: todayDb(), end: todayDb(), note: '', documentsToFollow: false, recordAsApproved: false }
  dialog.value?.showModal()
  const [typesRes, holidaysRes, closuresRes] = await Promise.all([
    supabase.from('leave_types').select('key, label, deducts_balance, requires_document').eq('is_active', true).order('sort_order'),
    s.countryCode
      ? supabase.from('public_holidays').select('date').eq('country_code', s.countryCode)
      : Promise.resolve({ data: [] as { date: string }[], error: null }),
    supabase.from('company_closures').select('date').eq('company_id', s.companyId),
  ])
  types.value = typesRes.data ?? []
  offDays.value = {
    holidays: (holidaysRes.data ?? []).map((h) => h.date),
    closures: (closuresRes.data ?? []).map((c) => c.date),
  }
  void loadContext(s)
}

/** The department colleagues (for the clash warning), then the date-bound numbers. */
async function loadContext(s: LeaveSubject): Promise<void> {
  const periodRes = await supabase.from('employment_periods').select('department_id').eq('person_id', s.personId).eq('company_id', s.companyId).in('status', ['active', 'pre_start']).limit(1).maybeSingle()
  const dept = periodRes.data?.department_id
  if (dept) {
    const { data } = await supabase.from('employment_periods').select('person_id').eq('company_id', s.companyId).eq('department_id', dept).in('status', ['active', 'pre_start'])
    colleagueIds.value = new Set((data ?? []).map((r) => r.person_id))
  } else {
    colleagueIds.value = new Set()
  }
  await loadTeam(s)
}

/** Everything that depends on the dates: what these dates could draw, and who is away then. Only the latest answer lands. */
async function loadTeam(s: LeaveSubject): Promise<void> {
  if (!form.value.start || !form.value.end || form.value.end < form.value.start) return
  const seq = ++loadSeq
  const [availRes, teamRes] = await Promise.all([
    supabase.rpc('requestable_leave', { p_person_id: s.personId, p_company_id: s.companyId, p_start: form.value.start, p_end: form.value.end }),
    supabase.rpc('team_leave', { p_company_id: s.companyId, p_from: form.value.start, p_to: form.value.end }),
  ])
  if (seq !== loadSeq) return
  available.value = availRes.error ? null : Number(availRes.data ?? 0)
  teamRows.value = (teamRes.data ?? []) as unknown as ClashRow[]
}
defineExpose({ open })

// A single day is the common case: moving the start drags a lagging end with it.
watch(
  () => form.value.start,
  (start) => {
    if (form.value.end < start) form.value = { ...form.value, end: start }
  },
)
watch([() => form.value.start, () => form.value.end], () => {
  if (subject.value) void loadTeam(subject.value)
})

async function submit(): Promise<void> {
  if (!subject.value) return
  error.value = null
  const parsed = leaveInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('request_leave', {
    p_person_id: subject.value.personId,
    p_leave_type_key: parsed.data.leaveTypeKey,
    p_start: parsed.data.start,
    p_end: parsed.data.end,
    p_note: parsed.data.note || undefined,
    p_documents_to_follow: parsed.data.documentsToFollow,
    p_record_as_approved: subject.value.onBehalf && form.value.recordAsApproved,
  })
  busy.value = false
  if (err) {
    error.value = friendlyLeaveError(err.message)
    console.error('Leave request failed:', err.message)
    return
  }
  const result = data as { request_id?: string; status?: string; working_days?: number } | null
  // The database queued the approvers' notifications; send the mail now.
  if (result?.status !== 'approved') void deliverNotifications()
  dialog.value?.close()
  emit('submitted', { status: result?.status ?? 'pending', workingDays: Number(result?.working_days ?? 0) })
}
</script>

<template>
  <dialog ref="dialog" class="leave-dialog" aria-labelledby="leave-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Leave</div>
      <h2 id="leave-title">{{ subject?.onBehalf ? `Record leave for ${subject.personName}` : 'Request leave' }}</h2>
      <p class="hint">
        {{ subject?.companyName }} · weekends{{ subject?.countryCode ? `, ${subject.countryCode} holidays` : '' }} and company
        closures do not count.
        <span v-if="subject && !subject.countryCode" class="warn">This employment has no country yet — set one on the company or location first.</span>
      </p>
      <div class="grid">
        <div class="field">
          <label for="lv-type">Type</label>
          <select id="lv-type" v-model="form.leaveTypeKey">
            <option v-for="t in types" :key="t.key" :value="t.key">{{ t.label }}</option>
          </select>
        </div>
        <div class="field">
          <label>Working days</label>
          <div class="preview" data-testid="working-days-preview">{{ previewDays }}</div>
        </div>
        <div class="field">
          <label for="lv-start">From</label>
          <input id="lv-start" v-model="form.start" type="date" required />
        </div>
        <div class="field">
          <label for="lv-end">To</label>
          <input id="lv-end" v-model="form.end" type="date" :min="form.start" required />
        </div>
      </div>
      <div v-if="after" class="preview-balance" :class="{ short: after.short }" data-testid="balance-preview">
        <span v-if="after.short">Not enough leave left: {{ after.before }} available, this request needs {{ previewDays }}.</span>
        <span v-else><b>{{ after.after }}</b> of {{ after.before }} days left after this request (pending requests already held aside).</span>
      </div>
      <div v-if="clashes.length" class="clash" data-testid="clash-warning">
        <b>Also away in the same department</b>
        <ul>
          <li v-for="c in clashes.slice(0, 4)" :key="c.id">{{ c.full_name }} · {{ c.start_date }} → {{ c.end_date }}{{ c.status === 'pending' ? ' (pending)' : '' }}</li>
        </ul>
        <small>Recorded anyway — this is a heads-up, not a block.</small>
      </div>
      <div class="field">
        <label for="lv-note">Note</label>
        <input id="lv-note" v-model="form.note" maxlength="1000" placeholder="Optional — for the approver" />
      </div>
      <label v-if="selectedType?.requires_document" class="check">
        <input v-model="form.documentsToFollow" type="checkbox" />
        A medical certificate will follow (attach it from the request afterwards)
      </label>
      <label v-if="subject?.onBehalf" class="check">
        <input v-model="form.recordAsApproved" type="checkbox" />
        Record as already approved
      </label>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy || !subject?.countryCode">
          {{ busy ? 'Saving…' : subject?.onBehalf ? 'Record leave' : 'Send request' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.leave-dialog { border: 0; border-radius: 15px; padding: 0; width: min(560px, calc(100vw - 36px)); box-shadow: 0 25px 100px #122f3038; color: var(--ink); }
.leave-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.warn { display: block; color: #a05a00; margin-top: 4px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.preview { font-size: 22px; font-weight: 600; padding: 4px 0 12px; }
.preview-balance { font-size: 12px; padding: 10px 12px; border-radius: 8px; background: #edf5ed; color: #3e744e; margin-bottom: 14px; }
.preview-balance.short { background: #fbf2df; color: #946d24; }
.clash { font-size: 11px; padding: 10px 12px; border-radius: 8px; background: #fbf2df; color: #7a5a1a; margin-bottom: 14px; }
.clash ul { margin: 6px 0; padding-left: 16px; }
.clash small { color: #946d24; }
.check { display: flex; gap: 8px; align-items: center; font-size: 12px; margin: 6px 0 10px; }
.check input { width: auto; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
