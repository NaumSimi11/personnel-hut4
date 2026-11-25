<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { addLocation, loadCompanyStructure, withOption, type StructureOption } from '@/lib/companyStructure'
import { locationSummary, missingFirst, type LocationRow } from '@/lib/employeeLocations'

/**
 * Everyone working in this company and their location (25 Nov): one dropdown
 * per person, those without a location first. HR fills the gaps here, and
 * adds a location the company does not have yet.
 */
const props = defineProps<{ companyId: string }>()

type Row = LocationRow & { job_title: string }

const auth = useAuthStore()
const rows = ref<Row[]>([])
const locations = ref<StructureOption[]>([])
const newLocation = ref('')
const savingId = ref<string | null>(null)
const adding = ref(false)
const error = ref<string | null>(null)

const canEdit = computed(() => auth.can(props.companyId, 'employment.edit'))
const summary = computed(() => locationSummary(rows.value))
const ordered = computed(() => missingFirst(rows.value))

async function load(): Promise<void> {
  error.value = null
  try {
    locations.value = (await loadCompanyStructure(props.companyId)).locations
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not load the locations.'
    return
  }
  const { data, error: err } = await supabase
    .from('employment_periods')
    .select('id, job_title, location_id, person:people!employment_periods_person_id_fkey(full_name)')
    .eq('company_id', props.companyId)
    .in('status', ['active', 'pre_start'])
  if (err) {
    error.value = 'Could not load the people working here.'
    console.error('Employee locations load failed:', err.message)
    return
  }
  rows.value = ((data ?? []) as unknown as { id: string; job_title: string; location_id: string | null; person: { full_name: string } | null }[]).map(
    (r) => ({ period_id: r.id, job_title: r.job_title, location_id: r.location_id, full_name: r.person?.full_name ?? '—' }),
  )
}

async function setLocation(row: Row, locationId: string): Promise<void> {
  error.value = null
  savingId.value = row.period_id
  const { error: err } = await supabase.rpc('set_employment_location', { p_period_id: row.period_id, p_location_id: locationId || null })
  savingId.value = null
  if (err) {
    error.value = err.message || 'Could not save the location.'
    console.error('set_employment_location failed:', err.message)
    return
  }
  rows.value = rows.value.map((r) => (r.period_id === row.period_id ? { ...r, location_id: locationId || null } : r))
}

async function add(): Promise<void> {
  adding.value = true
  error.value = null
  try {
    const added = await addLocation(props.companyId, newLocation.value)
    locations.value = withOption(locations.value, added)
    newLocation.value = ''
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not add the location.'
  } finally {
    adding.value = false
  }
}

watch(() => props.companyId, () => void load())
onMounted(() => void load())
</script>

<template>
  <div class="card" data-testid="employee-locations">
    <div class="card-head">
      <div>
        <h2>Where people work</h2>
        <p :class="{ gap: summary.missing }">{{ summary.line }}</p>
      </div>
      <div v-if="canEdit" class="add">
        <input v-model="newLocation" maxlength="80" placeholder="New location" aria-label="New location" @keydown.enter.prevent="add" />
        <button type="button" class="button secondary small-btn" :disabled="adding" @click="add">Add location</button>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <p v-if="!locations.length" class="hint">This company has no locations yet. Add one above, then pick it for each person.</p>
    <table v-if="rows.length" class="people">
      <thead><tr><th>Person</th><th>Job title</th><th>Location</th></tr></thead>
      <tbody>
        <tr v-for="r in ordered" :key="r.period_id" :class="{ missing: !r.location_id }">
          <td>{{ r.full_name }}</td>
          <td class="muted">{{ r.job_title }}</td>
          <td>
            <select
              :value="r.location_id ?? ''"
              :disabled="!canEdit || savingId === r.period_id"
              :aria-label="`Location of ${r.full_name}`"
              @change="setLocation(r, ($event.target as HTMLSelectElement).value)"
            >
              <option value="">No location</option>
              <option v-for="l in locations" :key="l.id" :value="l.id">{{ l.name }}</option>
            </select>
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<style scoped>
.in-card { margin: 12px 24px 0; }
.gap { color: #8a5a00; }
.add { display: flex; gap: 8px; align-items: center; }
.add input, select { border: 1px solid #dce3d7; padding: 7px 10px; font-size: 12px; background: #fff; }
.hint { margin: 0; padding: 12px 24px; border-top: 1px solid #edf0eb; font-size: 12px; color: var(--muted); }
.people { width: 100%; border-collapse: collapse; font-size: 12px; }
.people th, .people td { text-align: left; padding: 8px 24px; border-top: 1px solid #edf0eb; }
.missing td:first-child { font-weight: 600; }
.muted { color: var(--muted); }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
