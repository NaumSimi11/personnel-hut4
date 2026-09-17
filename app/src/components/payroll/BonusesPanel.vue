<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { formatAmount, todayDb } from '@/lib/compensation'
import { EMPLOYED_STATUSES } from '@/lib/leave'
import { bonusInput, type BonusForm } from '@/lib/payroll'
import type { Json } from '@/types/database'

/**
 * Bonuses for one company (plan 051): a pending bonus waits for the next
 * prepared period in its currency that has a line for the person, then
 * travels with it; reopening the period sends it back here. Reading needs
 * payroll.individual (the person reads their own on their profile); every
 * write goes through add_payroll_item / remove_payroll_item.
 */
const props = defineProps<{ companyId: string }>()
const emit = defineEmits<{ changed: [] }>()

type Item = {
  id: string
  person_id: string
  amount: number
  currency: string
  reason: string
  item_date: string
  period_id: string | null
  person: { full_name: string } | null
  period: { period_start: string; period_end: string; status: string } | null
}
type Person = { id: string; full_name: string }

const auth = useAuthStore()
const dialogs = useDialogStore()
const canEdit = computed(() => auth.can(props.companyId, 'payroll.individual'))

const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const items = ref<Item[]>([])
const people = ref<Person[]>([])
const adding = ref(false)
const form = ref<BonusForm>({ person_id: '', amount: '', currency: 'EUR', reason: '', item_date: todayDb() })

const pending = computed(() => items.value.filter((i) => i.period_id === null))
const included = computed(() => items.value.filter((i) => i.period_id !== null))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [itemsRes, peopleRes] = await Promise.all([
    supabase
      .from('payroll_items')
      .select('id, person_id, amount, currency, reason, item_date, period_id, person:people!payroll_items_person_id_fkey(full_name), period:payroll_periods!payroll_items_period_id_fkey(period_start, period_end, status)')
      .eq('company_id', props.companyId)
      .order('item_date', { ascending: false })
      .order('created_at', { ascending: false }),
    supabase
      .from('employment_periods')
      .select('person:people!employment_periods_person_id_fkey(id, full_name)')
      .eq('company_id', props.companyId)
      .in('status', EMPLOYED_STATUSES),
  ])
  loading.value = false
  if (itemsRes.error) {
    error.value = 'Could not load the bonuses.'
    console.error('Bonuses load failed:', itemsRes.error.message)
    return
  }
  items.value = (itemsRes.data ?? []) as unknown as Item[]
  if (peopleRes.error) console.error('Bonus people load failed:', peopleRes.error.message)
  const seen = new Map<string, Person>()
  for (const row of (peopleRes.data ?? []) as unknown as { person: Person | null }[]) {
    if (row.person) seen.set(row.person.id, row.person)
  }
  people.value = [...seen.values()].sort((a, b) => a.full_name.localeCompare(b.full_name))
}

function startAdd(): void {
  form.value = { person_id: '', amount: '', currency: items.value[0]?.currency ?? 'EUR', reason: '', item_date: todayDb() }
  error.value = null
  notice.value = null
  adding.value = true
}

async function submit(): Promise<void> {
  const parsed = bonusInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  error.value = null
  const { error: err } = await supabase.rpc('add_payroll_item', { p: { ...parsed.data, company_id: props.companyId } as unknown as Json })
  busy.value = false
  if (err) {
    error.value = err.code === '42501' ? 'You need payroll.individual in this company to record a bonus.' : err.message
    console.error('Bonus add failed:', err.message)
    return
  }
  const name = people.value.find((p) => p.id === parsed.data.person_id)?.full_name ?? 'the person'
  notice.value = `Bonus for ${name} recorded; it goes into the next prepared ${parsed.data.currency} period.`
  adding.value = false
  await load()
  emit('changed')
}

async function remove(item: Item): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Remove the ${formatAmount(Number(item.amount), item.currency)} bonus for ${item.person?.full_name ?? 'this person'}?`,
    hint: item.reason,
    confirmLabel: 'Remove',
  })
  if (!ok) return
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err } = await supabase.rpc('remove_payroll_item', { p_id: item.id })
  busy.value = false
  if (err) {
    error.value = err.message
    console.error('Bonus remove failed:', err.message)
    return
  }
  await load()
  emit('changed')
}

defineExpose({ reload: load })
watch(() => props.companyId, load)
onMounted(load)
</script>

<template>
  <div class="card" data-testid="bonuses-panel">
    <div class="card-head">
      <div>
        <h2>Bonuses</h2>
        <p>A bonus waits here until the next prepared period in its currency has a line for the person; reopening a period sends it back.</p>
      </div>
      <button v-if="canEdit && !adding" class="button small-btn" type="button" data-testid="bonus-add" @click="startAdd">Add a bonus</button>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="notice" class="notice" role="status">{{ notice }}</div>
      <div v-if="error" class="error" role="alert">{{ error }}</div>

      <form v-if="adding" class="form" novalidate data-testid="bonus-form" @submit.prevent="submit">
        <label class="wide"><span>Person</span>
          <select id="bonus-person" v-model="form.person_id">
            <option value="">— Choose —</option>
            <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
          </select>
        </label>
        <label><span>Amount</span><input id="bonus-amount" v-model="form.amount" inputmode="decimal" placeholder="e.g. 250" /></label>
        <label><span>Currency</span><input id="bonus-currency" v-model="form.currency" maxlength="3" autocapitalize="characters" /></label>
        <label class="wide"><span>Reason</span><input id="bonus-reason" v-model="form.reason" maxlength="200" placeholder="e.g. Quarter target met" /></label>
        <label><span>Date</span><input id="bonus-date" v-model="form.item_date" type="date" /></label>
        <div class="form-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="adding = false">Cancel</button>
          <button type="submit" class="button small-btn" :disabled="busy">{{ busy ? 'Saving…' : 'Record bonus' }}</button>
        </div>
      </form>

      <div v-if="!items.length" class="empty">No bonuses recorded.</div>
      <template v-else>
        <div class="group-label">Pending · {{ pending.length }}</div>
        <div v-if="!pending.length" class="empty small">Nothing waiting for a period.</div>
        <div v-for="i in pending" :key="i.id" class="item-row" data-testid="bonus-pending">
          <div class="row-text">
            <strong>{{ i.person?.full_name ?? 'Someone' }} <span class="muted">· {{ formatAmount(Number(i.amount), i.currency) }}</span></strong>
            <small>{{ i.reason }} · {{ i.item_date }}</small>
          </div>
          <button v-if="canEdit" class="button secondary small-btn" type="button" :disabled="busy" @click="remove(i)">Remove</button>
        </div>
        <template v-if="included.length">
          <div class="group-label">In a period · {{ included.length }}</div>
          <div v-for="i in included" :key="i.id" class="item-row swept" data-testid="bonus-included">
            <div class="row-text">
              <strong>{{ i.person?.full_name ?? 'Someone' }} <span class="muted">· {{ formatAmount(Number(i.amount), i.currency) }}</span></strong>
              <small>{{ i.reason }} · {{ i.item_date }} · in {{ i.period?.period_start }} → {{ i.period?.period_end }}</small>
            </div>
          </div>
        </template>
      </template>
    </template>
  </div>
</template>

<style scoped>
.group-label { padding: 12px 24px 4px; font-size: 10.5px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
.item-row { display: flex; align-items: center; gap: 13px; padding: 10px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.item-row.swept { opacity: 0.8; }
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.muted { font-weight: 400; color: var(--muted); }
.small-btn { font-size: 11px; padding: 7px 11px; }
.empty.small { padding: 8px 24px 12px; font-size: 11px; }
.form { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px 14px; padding: 16px 24px; background: #fafbf8; border-top: 1px solid var(--line); }
.form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.form label.wide { grid-column: span 2; }
.form .form-actions { grid-column: 1 / -1; display: flex; justify-content: flex-end; gap: 8px; }
.form input, .form select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
.notice { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
@media (max-width: 560px) { .form { grid-template-columns: 1fr; } .form label.wide { grid-column: auto; } }
</style>
