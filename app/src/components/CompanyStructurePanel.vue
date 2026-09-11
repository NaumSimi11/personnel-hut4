<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'

/**
 * Departments and locations for one company (plan 022). Rows with no
 * company are shared holding defaults and show as such. Both tables are
 * reference data: everyone signed in reads them, platform admins write.
 * Archiving is the only removal — employment history keeps its references.
 */

type Row = { id: string; name: string; company_id: string | null; archived_at: string | null; country_code?: string | null }

const props = defineProps<{ companyId: string }>()

const auth = useAuthStore()
const departments = ref<Row[]>([])
const locations = ref<Row[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const busy = ref(false)
const newDepartment = ref('')
const newLocation = ref('')
const newCountry = ref('')

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [deptRes, locRes] = await Promise.all([
    supabase
      .from('departments')
      .select('id, name, company_id, archived_at')
      .or(`company_id.eq.${props.companyId},company_id.is.null`)
      .is('archived_at', null)
      .order('name'),
    supabase
      .from('locations')
      .select('id, name, company_id, archived_at, country_code')
      .or(`company_id.eq.${props.companyId},company_id.is.null`)
      .is('archived_at', null)
      .order('name'),
  ])
  if (deptRes.error || locRes.error) {
    error.value = 'Could not load the structure. Check your access and connection.'
    console.error('Structure load failed:', deptRes.error?.message ?? locRes.error?.message)
  }
  departments.value = (deptRes.data ?? []) as Row[]
  locations.value = (locRes.data ?? []) as Row[]
  loading.value = false
}

function friendly(message: string): string {
  if (/row-level security/.test(message)) return 'Only platform admins can change the structure.'
  if (/unique|duplicate/i.test(message)) return 'That name already exists here.'
  return message
}

async function addDepartment(): Promise<void> {
  const name = newDepartment.value.trim()
  if (name.length < 2) {
    error.value = 'Enter the department name.'
    return
  }
  busy.value = true
  error.value = null
  const { error: err } = await supabase.from('departments').insert({ company_id: props.companyId, name })
  busy.value = false
  if (err) {
    error.value = friendly(err.message)
    return
  }
  newDepartment.value = ''
  await load()
}

async function addLocation(): Promise<void> {
  const name = newLocation.value.trim()
  const country = newCountry.value.trim().toUpperCase()
  if (name.length < 2) {
    error.value = 'Enter the location name.'
    return
  }
  if (country && !/^[A-Z]{2}$/.test(country)) {
    error.value = 'Country must be a two-letter code (MK, DE…).'
    return
  }
  busy.value = true
  error.value = null
  const { error: err } = await supabase
    .from('locations')
    .insert({ company_id: props.companyId, name, country_code: country || null })
  busy.value = false
  if (err) {
    error.value = friendly(err.message)
    return
  }
  newLocation.value = ''
  newCountry.value = ''
  await load()
}

async function archive(table: 'departments' | 'locations', row: Row): Promise<void> {
  if (row.company_id === null) {
    error.value = 'Shared holding defaults are managed by an admin at the holding level.'
    return
  }
  if (!window.confirm(`Archive ${row.name}? Existing records keep it; it disappears from pickers.`)) return
  busy.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from(table)
    .update({ archived_at: new Date().toISOString() })
    .eq('id', row.id)
    .select('id')
    .maybeSingle()
  busy.value = false
  if (err || !data) {
    error.value = friendly(err?.message ?? 'row-level security')
    return
  }
  await load()
}

onMounted(load)
</script>

<template>
  <div>
    <p v-if="error" class="error-note" role="alert" style="margin-bottom: 16px">{{ error }}</p>
    <div v-if="loading" class="empty">Loading structure…</div>
    <div v-else class="two-up">
      <div class="card">
        <div class="card-head">
          <div>
            <h2>Departments</h2>
            <p>Used on employment records. Shared ones apply across the holding.</p>
          </div>
        </div>
        <div v-if="!departments.length" class="empty">No departments yet.</div>
        <div v-else>
          <div v-for="d in departments" :key="d.id" class="structure-row">
            <div class="row-text">
              <strong>{{ d.name }}</strong>
              <small>{{ d.company_id ? 'This company' : 'Shared across the holding' }}</small>
            </div>
            <button
              v-if="auth.isAdmin && d.company_id"
              class="button secondary small-btn"
              type="button"
              :disabled="busy"
              @click="archive('departments', d)"
            >
              Archive
            </button>
          </div>
        </div>
        <form v-if="auth.isAdmin" class="add-form" @submit.prevent="addDepartment">
          <input id="new-department" v-model="newDepartment" maxlength="80" placeholder="New department" aria-label="New department" />
          <button class="button small-btn" type="submit" :disabled="busy">Add department</button>
        </form>
      </div>

      <div class="card">
        <div class="card-head">
          <div>
            <h2>Locations</h2>
            <p>Offices and sites. Country codes feed payroll and reports later.</p>
          </div>
        </div>
        <div v-if="!locations.length" class="empty">No locations yet.</div>
        <div v-else>
          <div v-for="l in locations" :key="l.id" class="structure-row">
            <div class="row-text">
              <strong>{{ l.name }}<template v-if="l.country_code"> · {{ l.country_code }}</template></strong>
              <small>{{ l.company_id ? 'This company' : 'Shared across the holding' }}</small>
            </div>
            <button
              v-if="auth.isAdmin && l.company_id"
              class="button secondary small-btn"
              type="button"
              :disabled="busy"
              @click="archive('locations', l)"
            >
              Archive
            </button>
          </div>
        </div>
        <form v-if="auth.isAdmin" class="add-form" @submit.prevent="addLocation">
          <input id="new-location" v-model="newLocation" maxlength="80" placeholder="New location" aria-label="New location" />
          <input id="new-location-country" v-model="newCountry" maxlength="2" class="country" placeholder="MK" aria-label="Country code" />
          <button class="button small-btn" type="submit" :disabled="busy">Add location</button>
        </form>
      </div>
    </div>
  </div>
</template>

<style scoped>
.two-up { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; align-items: start; }
@media (max-width: 900px) { .two-up { grid-template-columns: 1fr; } }
.structure-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; }
.row-text { flex: 1; min-width: 0; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 3px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.add-form { display: flex; gap: 8px; padding: 14px 24px; border-top: 1px solid var(--line); background: #fafbf9; flex-wrap: wrap; }
.add-form input {
  flex: 1;
  min-width: 160px;
  border: 1px solid #dce3d7;
  padding: 8px 10px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
}
.add-form .country { flex: 0 0 64px; min-width: 64px; text-transform: uppercase; }
</style>
