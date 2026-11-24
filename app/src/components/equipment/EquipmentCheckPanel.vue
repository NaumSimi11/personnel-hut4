<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { deliverNotifications } from '@/lib/notificationsApi'
import { localToday } from '@/lib/inventoryPrint'
import { CHECK_ANSWERS, checkLine, checkProgress, needsFollowUp, type CheckAnswer } from '@/lib/equipmentCheck'

/**
 * The yearly equipment check, for whoever manages equipment (24 Nov, 0130):
 * start one per company with a deadline, watch the answers come in, follow
 * up what is missing or wrong, close it.
 */
type Company = { id: string; name: string }
type Check = { id: string; name: string; deadline: string; status: string; started_at: string; closed_at: string | null }
type Item = {
  id: string
  answer: CheckAnswer | null
  note: string | null
  followed_up_at: string | null
  follow_up_note: string | null
  asset_id: string
  person: { full_name: string } | null
  asset: { asset_tag: string; model: string | null } | null
}
type Filter = 'all' | 'open' | 'follow'

const auth = useAuthStore()
const dialogs = useDialogStore()
const companies = ref<Company[]>([])
const companyId = ref('')
const check = ref<Check | null>(null)
const items = ref<Item[]>([])
const filter = ref<Filter>('all')
const deadline = ref('')
const name = ref('')
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const progress = computed(() => checkProgress(items.value))
const shown = computed(() =>
  items.value.filter((i) => (filter.value === 'open' ? !i.answer : filter.value === 'follow' ? needsFollowUp(i) : true)),
)

async function loadCompanies(): Promise<void> {
  const { data, error: err } = await supabase.from('companies').select('id, name').is('archived_at', null).order('name')
  if (err) {
    error.value = 'Could not load companies.'
    console.error('Companies load failed:', err.message)
    return
  }
  companies.value = (data ?? []).filter((c) => auth.can(c.id, 'it.assign'))
  if (!companyId.value && companies.value[0]) companyId.value = companies.value[0].id
}

async function loadCheck(): Promise<void> {
  check.value = null
  items.value = []
  if (!companyId.value) return
  const { data, error: err } = await supabase
    .from('equipment_checks')
    .select('id, name, deadline, status, started_at, closed_at')
    .eq('company_id', companyId.value)
    .order('started_at', { ascending: false })
    .limit(1)
  if (err) {
    error.value = 'Could not load the equipment check.'
    console.error('Equipment check load failed:', err.message)
    return
  }
  check.value = (data ?? [])[0] ?? null
  if (!check.value) return
  const res = await supabase
    .from('equipment_check_items')
    .select('id, answer, note, followed_up_at, follow_up_note, asset_id, person:people!equipment_check_items_person_id_fkey(full_name), asset:assets(asset_tag, model)')
    .eq('check_id', check.value.id)
  if (res.error) {
    error.value = 'Could not load the answers.'
    console.error('Equipment check items load failed:', res.error.message)
    return
  }
  items.value = ((res.data ?? []) as unknown as Item[]).sort((a, b) => (a.person?.full_name ?? '').localeCompare(b.person?.full_name ?? ''))
}

async function start(): Promise<void> {
  error.value = null
  notice.value = null
  if (!deadline.value) {
    error.value = 'Pick the deadline.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('start_equipment_check', {
    p_company_id: companyId.value,
    p_deadline: deadline.value,
    p_name: name.value.trim() || undefined,
  })
  busy.value = false
  if (err) {
    error.value = err.message || 'Could not start the check.'
    console.error('start_equipment_check failed:', err.message)
    return
  }
  const r = data as { lines: number; people: number }
  notice.value = `Started: ${r.lines} item${r.lines === 1 ? '' : 's'} to confirm by ${r.people} ${r.people === 1 ? 'person' : 'people'}. Each has been told.`
  void deliverNotifications()
  await loadCheck()
}

async function followUp(item: Item): Promise<void> {
  const reply = await dialogs.askReason({
    title: 'How was this settled?',
    eyebrow: item.asset?.asset_tag ?? 'Equipment',
    hint: item.note ? `${item.person?.full_name ?? 'The holder'} wrote: ${item.note}` : undefined,
    label: 'What was done (returned, marked lost, repaired, details corrected…)',
    confirmLabel: 'Save',
  })
  if (!reply) return
  const { error: err } = await supabase.rpc('follow_up_equipment_check', { p_item_id: item.id, p_note: reply.reason })
  if (err) {
    error.value = err.message || 'Could not save the follow-up.'
    console.error('follow_up_equipment_check failed:', err.message)
    return
  }
  await loadCheck()
}

async function close(): Promise<void> {
  if (!check.value) return
  const ok = await dialogs.confirmAction({
    title: `Close ${check.value.name}?`,
    hint: progress.value.open ? `${progress.value.open} item${progress.value.open === 1 ? ' is' : 's are'} still unanswered and stay so on the record.` : 'Every item has an answer.',
    confirmLabel: 'Close the check',
  })
  if (!ok) return
  const { error: err } = await supabase.rpc('close_equipment_check', { p_check_id: check.value.id })
  if (err) {
    error.value = err.message || 'Could not close the check.'
    console.error('close_equipment_check failed:', err.message)
    return
  }
  await loadCheck()
}

function answerLabel(key: CheckAnswer | null): string {
  return CHECK_ANSWERS.find((a) => a.key === key)?.label ?? 'Not answered yet'
}

watch(companyId, () => {
  void loadCheck()
})
onMounted(async () => {
  await loadCompanies()
  await loadCheck()
})
</script>

<template>
  <div v-if="companies.length" class="card" data-testid="equipment-check-panel">
    <div class="card-head">
      <div>
        <h2>Equipment check</h2>
        <p>Once a year, everyone who holds equipment confirms each item. Missing or wrong items come back to you to follow up.</p>
      </div>
      <select v-if="companies.length > 1" v-model="companyId" aria-label="Company" data-testid="check-company">
        <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
      </select>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>

    <div v-if="!check || check.status === 'closed'" class="start">
      <p v-if="check" class="muted">Last check: {{ check.name }}, closed {{ check.closed_at?.slice(0, 10) }}.</p>
      <label>Name <input v-model="name" maxlength="120" :placeholder="`Equipment check ${localToday().slice(0, 4)}`" /></label>
      <label>Answer by <input v-model="deadline" type="date" :min="localToday()" data-testid="check-deadline" /></label>
      <button type="button" class="button small-btn" :disabled="busy" data-testid="check-start" @click="start">{{ busy ? 'Starting…' : 'Start the check' }}</button>
    </div>

    <template v-if="check">
      <div class="summary">
        <strong>{{ checkLine(check) }}</strong>
        <span>{{ progress.have }} still have · {{ progress.missing }} missing · {{ progress.issue }} with a problem · {{ progress.open }} not answered · {{ progress.toFollowUp }} to follow up</span>
        <div class="tools">
          <select v-model="filter" aria-label="Show">
            <option value="all">All items ({{ progress.total }})</option>
            <option value="open">Not answered ({{ progress.open }})</option>
            <option value="follow">To follow up ({{ progress.toFollowUp }})</option>
          </select>
          <button v-if="check.status === 'open'" type="button" class="button secondary small-btn" data-testid="check-close" @click="close">Close the check</button>
        </div>
      </div>
      <table class="items">
        <thead><tr><th>Person</th><th>Item</th><th>Answer</th><th></th></tr></thead>
        <tbody>
          <tr v-for="i in shown" :key="i.id">
            <td>{{ i.person?.full_name ?? '—' }}</td>
            <td><router-link :to="{ name: 'asset', params: { assetId: i.asset_id } }">{{ i.asset?.asset_tag ?? 'Item' }}</router-link> <span class="muted">{{ i.asset?.model ?? '' }}</span></td>
            <td :class="{ flag: i.answer === 'missing' || i.answer === 'issue', muted: !i.answer }">
              {{ answerLabel(i.answer) }}<span v-if="i.note"> — {{ i.note }}</span>
              <div v-if="i.followed_up_at" class="muted">Settled: {{ i.follow_up_note }}</div>
            </td>
            <td><button v-if="needsFollowUp(i)" type="button" class="button secondary small-btn" @click="followUp(i)">Follow up</button></td>
          </tr>
          <tr v-if="!shown.length"><td colspan="4" class="muted">Nothing to show.</td></tr>
        </tbody>
      </table>
    </template>
  </div>
</template>

<style scoped>
.in-card, .notice { margin: 12px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.start { display: flex; gap: 12px; align-items: flex-end; flex-wrap: wrap; padding: 14px 24px; border-top: 1px solid #edf0eb; font-size: 12px; }
.start label { display: flex; flex-direction: column; gap: 4px; }
.start .muted { width: 100%; margin: 0; }
.summary { display: flex; flex-direction: column; gap: 6px; padding: 14px 24px; border-top: 1px solid #edf0eb; font-size: 12px; }
.tools { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.items { width: 100%; border-collapse: collapse; font-size: 12px; }
.items th, .items td { text-align: left; padding: 8px 24px; border-top: 1px solid #edf0eb; vertical-align: top; }
.flag { color: #8a3b12; }
.muted { color: var(--muted); }
.small-btn { font-size: 11px; padding: 7px 11px; }
select, input { border: 1px solid #dce3d7; padding: 7px 10px; font-size: 12px; background: #fff; }
</style>
