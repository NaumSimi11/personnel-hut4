<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'

/**
 * Restricted personal details (birth date, address, emergency contact,
 * notes) — gated by RLS on `person_private_details` (self, or a viewer
 * holding `personal.view` in a company where the person has employment).
 * This card only decides whether to attempt the load/render; RLS remains
 * the actual gate, so a null row for a permitted viewer just means
 * "nothing recorded yet".
 */
const props = defineProps<{ personId: string }>()

type Address = { line: string }
type EmergencyContact = { name: string; phone: string }

const auth = useAuthStore()
const visible = computed(() => auth.isAdmin || auth.personId === props.personId)

const loading = ref(true)
const editing = ref(false)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const hasRecord = ref(false)

const form = ref({
  birthDate: '',
  addressLine: '',
  contactName: '',
  contactPhone: '',
  notes: '',
})

function resetForm(): void {
  form.value = { birthDate: '', addressLine: '', contactName: '', contactPhone: '', notes: '' }
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('person_private_details')
    .select('birth_date, address, emergency_contacts, notes')
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
  const contacts = (data?.emergency_contacts ?? []) as EmergencyContact[]
  const firstContact = contacts[0] ?? { name: '', phone: '' }
  form.value = {
    birthDate: data?.birth_date ?? '',
    addressLine: address?.line ?? '',
    contactName: firstContact.name ?? '',
    contactPhone: firstContact.phone ?? '',
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

async function save(): Promise<void> {
  busy.value = true
  error.value = null
  notice.value = null
  const emergencyContacts: EmergencyContact[] =
    form.value.contactName.trim() || form.value.contactPhone.trim()
      ? [{ name: form.value.contactName.trim(), phone: form.value.contactPhone.trim() }]
      : []
  const { error: err } = await supabase.from('person_private_details').upsert({
    person_id: props.personId,
    birth_date: form.value.birthDate || null,
    address: form.value.addressLine.trim() ? { line: form.value.addressLine.trim() } : null,
    emergency_contacts: emergencyContacts,
    notes: form.value.notes.trim() || null,
  })
  busy.value = false
  if (err) {
    error.value = 'Could not save private details.'
    console.error('Private details save failed:', err.message)
    return
  }
  hasRecord.value = true
  editing.value = false
  notice.value = 'Private details saved.'
}

onMounted(async () => {
  if (visible.value) await load()
  else loading.value = false
})
</script>

<template>
  <div v-if="visible" class="card">
    <div class="card-head">
      <div>
        <h2>Private details <span class="badge amber">Sensitive</span></h2>
        <p>Visible only to the person and permitted HR access.</p>
      </div>
      <button
        v-if="!loading && !editing"
        class="button secondary"
        type="button"
        @click="startEdit"
      >
        {{ hasRecord ? 'Edit' : 'Add details' }}
      </button>
    </div>

    <div class="card-body">
      <div v-if="loading" class="empty">Loading private details…</div>

      <form v-else-if="editing" novalidate @submit.prevent="save">
        <div class="field">
          <label for="pd-birth-date">Birth date</label>
          <input id="pd-birth-date" v-model="form.birthDate" type="date" />
        </div>
        <div class="field">
          <label for="pd-address">Address</label>
          <input id="pd-address" v-model="form.addressLine" maxlength="200" />
        </div>
        <div class="field">
          <label for="pd-contact-name">Emergency contact name</label>
          <input id="pd-contact-name" v-model="form.contactName" maxlength="120" />
        </div>
        <div class="field">
          <label for="pd-contact-phone">Emergency contact phone</label>
          <input id="pd-contact-phone" v-model="form.contactPhone" maxlength="40" />
        </div>
        <div class="field">
          <label for="pd-notes">Notes</label>
          <textarea id="pd-notes" v-model="form.notes" rows="4" maxlength="2000"></textarea>
        </div>
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
            <dt>Emergency contact</dt>
            <dd>
              <template v-if="form.contactName || form.contactPhone">
                {{ form.contactName || '—' }} · {{ form.contactPhone || '—' }}
              </template>
              <template v-else>—</template>
            </dd>
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
.field textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 11px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
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
.details dd { margin: 0; flex: 1; font-size: 12px; min-width: 0; }
.details dd.notes { white-space: pre-wrap; }
</style>
