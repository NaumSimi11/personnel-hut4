<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useDialogStore } from '@/stores/dialogs'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import { longDate } from '@/lib/candidatePool'

/**
 * An imported hire without an employee record (plan 052): the Zoho Recruit
 * import never creates a person (blueprint §5), so a hired application lands
 * here with, at most, a proposed match. HR confirms the link or declines
 * the proposal; `link_hired_application` decides, and this card only asks.
 * Shown by ApplicationPage when the viewer has employment.edit — a hint, the
 * RPC checks again.
 */

export type ZohoHire = {
  hired_date?: string | null
  proposed_person?: { id: string; full_name: string; match: string } | null
}

type PeriodRow = {
  person_id: string
  start_date: string
  person: { full_name: string } | null
}

const MATCHED_BY: Record<string, string> = { email: 'email', phone: 'phone', name: 'name' }

const props = defineProps<{ applicationId: string; companyId: string; zoho: ZohoHire }>()
const emit = defineEmits<{ changed: [] }>()

const dialogs = useDialogStore()
const employees = ref<{ id: string; name: string }[]>([])
/** Preselected to the proposal only once `load` finds it among the employees here. */
const personId = ref('')
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)

const proposal = computed(() => props.zoho.proposed_person ?? null)
const hireLine = computed(() =>
  props.zoho.hired_date ? `Zoho Recruit recorded this hire on ${longDate(props.zoho.hired_date)}.` : 'Zoho Recruit recorded this hire.',
)
const proposalLine = computed(() =>
  proposal.value
    ? `Proposed employee record: ${proposal.value.full_name} (matched by ${MATCHED_BY[proposal.value.match] ?? proposal.value.match}).`
    : 'No employee record was proposed — pick one, or leave it unlinked.',
)
const selected = computed(() => employees.value.find((e) => e.id === personId.value) ?? null)

/** One entry per person with an employment record here, whichever period; RLS (people.view) scopes it. */
function uniquePeople(rows: PeriodRow[]): { id: string; name: string }[] {
  const byId = new Map<string, string>()
  rows.forEach((r) => {
    if (!byId.has(r.person_id)) byId.set(r.person_id, r.person?.full_name ?? '—')
  })
  return [...byId].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name))
}

async function load(): Promise<void> {
  loading.value = true
  const { data, error: err } = await supabase
    .from('employment_periods')
    .select('person_id, start_date, person:people!employment_periods_person_id_fkey(full_name)')
    .eq('company_id', props.companyId)
    .order('start_date', { ascending: false })
  loading.value = false
  if (err) {
    error.value = 'Could not load the employees of this company.'
    console.error('Imported hire employees load failed:', err.message)
    return
  }
  employees.value = uniquePeople((data ?? []) as PeriodRow[])
  // A proposal with no employment record here stays a sentence; the select
  // keeps its placeholder and "Link" waits for a pick.
  const proposed = props.zoho.proposed_person?.id
  if (proposed && employees.value.some((e) => e.id === proposed)) personId.value = proposed
}

async function callLink(target: string | null): Promise<boolean> {
  error.value = null
  busy.value = true
  const { error: err } = await supabase.rpc('link_hired_application', {
    p_application_id: props.applicationId,
    p_person_id: target,
  })
  busy.value = false
  if (err) {
    error.value = friendlyRecruitmentError(err.message)
    return false
  }
  return true
}

async function link(): Promise<void> {
  const person = selected.value
  if (!person) {
    error.value = 'Pick the employee record first.'
    return
  }
  const ok = await dialogs.confirmAction({
    eyebrow: 'Imported hire',
    title: `Link this hire to ${person.name}?`,
    hint: 'The application joins their employment record in this company. This cannot be undone here.',
    confirmLabel: 'Link to this employee',
  })
  if (!ok) return
  if (await callLink(person.id)) emit('changed')
}

async function decline(): Promise<void> {
  const person = proposal.value
  if (!person) return
  const ok = await dialogs.confirmAction({
    eyebrow: 'Imported hire',
    title: `Not ${person.full_name}?`,
    hint: 'The proposal is cleared. You can still pick another employee record, or leave the hire unlinked.',
    confirmLabel: 'Not the same person',
    danger: true,
  })
  if (!ok) return
  if (await callLink(null)) {
    personId.value = ''
    emit('changed')
  }
}

onMounted(load)
</script>

<template>
  <section class="card hire-link" data-testid="hire-link-card" aria-label="Imported hire">
    <div class="card-head">
      <div>
        <div class="eyebrow">Imported hire</div>
        <h2>Which employee record is this?</h2>
        <p>{{ hireLine }}</p>
      </div>
    </div>
    <div class="card-body">
      <p class="proposal" :class="{ muted: !proposal }" data-testid="hire-link-proposal">{{ proposalLine }}</p>
      <div class="field">
        <label for="hire-link-person">Employee record</label>
        <select id="hire-link-person" v-model="personId" :disabled="loading || busy" data-testid="hire-link-person">
          <option value="">{{ loading ? 'Loading employees…' : 'Choose an employee' }}</option>
          <option v-for="e in employees" :key="e.id" :value="e.id">{{ e.name }}</option>
        </select>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button" type="button" :disabled="busy || !personId" data-testid="hire-link-confirm" @click="link">
          Link to this employee
        </button>
        <button v-if="proposal" class="button secondary" type="button" :disabled="busy" data-testid="hire-link-decline" @click="decline">
          Not the same person
        </button>
      </div>
    </div>
  </section>
</template>

<style scoped>
.hire-link { margin-bottom: 20px; }
.proposal { margin: 0 0 16px; font-size: 12px; font-weight: 550; }
.proposal.muted { color: var(--muted); font-weight: 400; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
</style>
