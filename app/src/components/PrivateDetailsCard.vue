<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import PrivateDetailsFields, { type PrivateDetailsForm } from '@/components/PrivateDetailsFields.vue'

/**
 * Restricted personal details — birth date, address, national ID, bank
 * account, emergency contact, notes — gated by RLS on
 * `person_private_details` (self, or personal.view in a company where the
 * person has employment). The card renders for exactly those viewers
 * (plan 046: it used to hide from Company HR); RLS remains the gate, so a
 * null row for a permitted viewer just means "nothing recorded yet".
 */
const props = defineProps<{ personId: string; companyIds: string[] }>()

type Address = { line: string }
type EmergencyContact = { name?: string; relationship?: string; phone?: string }
type BankAccount = { bank?: string; account_number?: string }

const auth = useAuthStore()
const visible = computed(
  () => auth.personId === props.personId || props.companyIds.some((c) => auth.can(c, 'personal.view')),
)

const loading = ref(true)
const editing = ref(false)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const hasRecord = ref(false)

const EMPTY: PrivateDetailsForm = {
  birthDate: '',
  addressLine: '',
  nationalId: '',
  bankName: '',
  bankAccountNumber: '',
  emergencyName: '',
  emergencyRelationship: '',
  emergencyPhone: '',
  notes: '',
}
const form = ref<PrivateDetailsForm>({ ...EMPTY })

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('person_private_details')
    .select('birth_date, address, national_id, bank_account, emergency_contacts, notes')
    .eq('person_id', props.personId)
    .maybeSingle()
  if (err) {
    error.value = 'Could not load private details.'
    console.error('Private details load failed:', err.message)
    loading.value = false
    return
  }
  hasRecord.value = data !== null
  const address = (data?.address ?? null) as Address | null
  const bank = (data?.bank_account ?? null) as BankAccount | null
  const contacts = (data?.emergency_contacts ?? []) as EmergencyContact[]
  const first = contacts[0] ?? {}
  form.value = {
    birthDate: data?.birth_date ?? '',
    addressLine: address?.line ?? '',
    nationalId: data?.national_id ?? '',
    bankName: bank?.bank ?? '',
    bankAccountNumber: bank?.account_number ?? '',
    emergencyName: first.name ?? '',
    emergencyRelationship: first.relationship ?? '',
    emergencyPhone: first.phone ?? '',
    notes: data?.notes ?? '',
  }
  loading.value = false
}

function startEdit(): void {
  error.value = null
  notice.value = null
  editing.value = true
}

function cancelEdit(): void {
  editing.value = false
  error.value = null
  void load()
}

/** The filled keys of a small object, trimmed; nothing when all are blank. */
function filled<T extends Record<string, string>>(source: T): Partial<T> | null {
  const entries = Object.entries(source).flatMap(([k, v]) => (v.trim() ? [[k, v.trim()] as const] : []))
  return entries.length ? (Object.fromEntries(entries) as Partial<T>) : null
}

async function save(): Promise<void> {
  busy.value = true
  error.value = null
  notice.value = null
  const f = form.value
  const contact = filled({ name: f.emergencyName, relationship: f.emergencyRelationship, phone: f.emergencyPhone })
  const bank = filled({ bank: f.bankName, account_number: f.bankAccountNumber })
  const { error: err } = await supabase.from('person_private_details').upsert({
    person_id: props.personId,
    birth_date: f.birthDate || null,
    address: f.addressLine.trim() ? { line: f.addressLine.trim() } : null,
    national_id: f.nationalId.trim() || null,
    bank_account: bank,
    emergency_contacts: contact ? [contact] : [],
    notes: f.notes.trim() || null,
  })
  busy.value = false
  if (err) {
    error.value = friendly(err.message)
    console.error('Private details save failed:', err.message)
    return
  }
  hasRecord.value = true
  editing.value = false
  notice.value = 'Private details saved.'
}

function friendly(message: string): string {
  if (/national_id/.test(message)) return 'The national ID must be between 4 and 32 characters.'
  if (/row-level security/.test(message)) return 'Saving private details needs personal.view in this company.'
  return 'Could not save private details.'
}

const bankLine = computed(() => [form.value.bankName, form.value.bankAccountNumber].filter(Boolean).join(' · '))
const contactLine = computed(() => [form.value.emergencyName, form.value.emergencyRelationship, form.value.emergencyPhone].filter(Boolean).join(' · '))

watch(visible, (v) => {
  if (v && loading.value) void load()
})

onMounted(async () => {
  if (visible.value) await load()
  else loading.value = false
})
</script>

<template>
  <div v-if="visible" class="card" data-testid="private-details-card">
    <div class="card-head">
      <div>
        <h2>Private details <span class="badge amber">Sensitive</span></h2>
        <p>Visible to the person and to HR with private access. The national ID and bank account are what payroll needs.</p>
      </div>
      <button
        v-if="!loading && !editing"
        class="button secondary"
        type="button"
        data-testid="private-details-edit"
        @click="startEdit"
      >
        {{ hasRecord ? 'Edit' : 'Add details' }}
      </button>
    </div>

    <div class="card-body">
      <div v-if="loading" class="empty">Loading private details…</div>

      <form v-else-if="editing" novalidate @submit.prevent="save">
        <PrivateDetailsFields v-model="form" prefix="pd" />
        <p v-if="error" class="error-note" role="alert">{{ error }}</p>
        <div class="actions">
          <button class="button secondary" type="button" :disabled="busy" @click="cancelEdit">
            Cancel
          </button>
          <button class="button" type="submit" :disabled="busy">
            {{ busy ? 'Saving…' : 'Save' }}
          </button>
        </div>
      </form>

      <template v-else>
        <output v-if="notice" class="notice">{{ notice }}</output>
        <p v-if="error" class="error-note" role="alert">{{ error }}</p>
        <div v-if="!hasRecord" class="empty">Nothing recorded yet.</div>
        <dl v-else class="details">
          <div class="row">
            <dt>Birth date</dt>
            <dd>{{ form.birthDate || '—' }}</dd>
          </div>
          <div class="row">
            <dt>Address</dt>
            <dd>{{ form.addressLine || '—' }}</dd>
          </div>
          <div class="row">
            <dt>National ID</dt>
            <dd data-testid="pd-national-id-value">{{ form.nationalId || '—' }}</dd>
          </div>
          <div class="row">
            <dt>Bank account</dt>
            <dd data-testid="pd-bank-value">{{ bankLine || '—' }}</dd>
          </div>
          <div class="row">
            <dt>Emergency contact</dt>
            <dd data-testid="pd-contact-value">{{ contactLine || '—' }}</dd>
          </div>
          <div class="row">
            <dt>Notes</dt>
            <dd class="notes">{{ form.notes || '—' }}</dd>
          </div>
        </dl>
      </template>
    </div>
  </div>
</template>

<style scoped>
h2 { display: flex; align-items: center; gap: 9px; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 4px; }
.notice {
  display: block;
  padding: 12px 15px;
  border-radius: 9px;
  background: #edf5ed;
  color: #3e744e;
  font-size: 12px;
  margin-bottom: 16px;
}
.details { margin: 0; }
.details .row {
  display: flex;
  gap: 12px;
  padding: 10px 0;
  border-top: 1px solid #edf0eb;
}
.details .row:first-child { border-top: 0; padding-top: 0; }
.details dt { flex: 0 0 140px; font-size: 11px; color: var(--muted); }
.details dd { margin: 0; flex: 1; font-size: 12px; min-width: 0; overflow-wrap: anywhere; }
.details dd.notes { white-space: pre-wrap; }
</style>
