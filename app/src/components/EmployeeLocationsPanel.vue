<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { loadCompanyStructure, withOption, type StructureOption } from '@/lib/companyStructure'
import { locationName, locationSummary, missingFirst, type LocationRow } from '@/lib/employeeLocations'
import LocationInput from '@/components/locations/LocationInput.vue'

/**
 * Everyone working in this company and their location (25 Nov): one dropdown
 * per person, those without a location first. HR types each one; a new
 * place becomes one of the company's locations.
 */
const props = defineProps<{ companyId: string }>()

type Row = LocationRow & { job_title: string; location_name: string }

const auth = useAuthStore()
const rows = ref<Row[]>([])
const locations = ref<StructureOption[]>([])
const savingId = ref<string | null>(null)
const drafts = ref<Record<string, string>>({})
const suggestions = computed(() => locations.value.map((l) => l.name))
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
    .select('id, job_title, location_id, location:locations(name), person:people!employment_periods_person_id_fkey(full_name)')
    .eq('company_id', props.companyId)
    .in('status', ['active', 'pre_start'])
  if (err) {
    error.value = 'Could not load the people working here.'
    console.error('Employee locations load failed:', err.message)
    return
  }
  rows.value = (
    (data ?? []) as unknown as { id: string; job_title: string; location_id: string | null; location: { name: string } | null; person: { full_name: string } | null }[]
  ).map((r) => ({ period_id: r.id, job_title: r.job_title, location_id: r.location_id, location_name: r.location?.name ?? '', full_name: r.person?.full_name ?? '—' }))
  drafts.value = Object.fromEntries(rows.value.map((r) => [r.period_id, r.location_name]))
}

async function setLocation(row: Row): Promise<void> {
  const typed = drafts.value[row.period_id] ?? ''
  if (typed.trim() === row.location_name) return
  const parsed = locationName.safeParse(typed)
  if (!parsed.success) {
    error.value = `${row.full_name}: ${parsed.error.issues[0]?.message ?? 'check the location.'}`
    return
  }
  error.value = null
  savingId.value = row.period_id
  const { data, error: err } = await supabase.rpc('set_employment_location_name', { p_period_id: row.period_id, p_name: parsed.data })
  savingId.value = null
  if (err) {
    error.value = err.message || 'Could not save the location.'
    console.error('set_employment_location_name failed:', err.message)
    return
  }
  const saved = data as { location_id: string; name: string }
  rows.value = rows.value.map((r) => (r.period_id === row.period_id ? { ...r, location_id: saved.location_id, location_name: saved.name } : r))
  drafts.value = { ...drafts.value, [row.period_id]: saved.name }
  if (!locations.value.some((l) => l.id === saved.location_id)) locations.value = withOption(locations.value, { id: saved.location_id, name: saved.name })
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
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <p class="hint">Type where each person works (Skopje, Struga, Vilnius, Lithuania…) and press Enter or Save.</p>
    <table v-if="rows.length" class="people">
      <thead><tr><th>Person</th><th>Job title</th><th>Location</th></tr></thead>
      <tbody>
        <tr v-for="r in ordered" :key="r.period_id" :class="{ missing: !r.location_id }">
          <td>{{ r.full_name }}</td>
          <td class="muted">{{ r.job_title }}</td>
          <td>
            <span class="cell">
              <LocationInput
                :id="`loc-${r.period_id}`"
                v-model="drafts[r.period_id]"
                :suggestions="suggestions"
                :disabled="!canEdit || savingId === r.period_id"
                :aria-label="`Location of ${r.full_name}`"
                @commit="setLocation(r)"
              />
              <button v-if="canEdit && (drafts[r.period_id] ?? '').trim() !== r.location_name" type="button" class="button small-btn" :disabled="savingId === r.period_id" @click="setLocation(r)">Save</button>
            </span>
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<style scoped>
.in-card { margin: 12px 24px 0; }
.gap { color: #8a5a00; }
.hint { margin: 0; padding: 12px 24px; border-top: 1px solid #edf0eb; font-size: 12px; color: var(--muted); }
.people { width: 100%; border-collapse: collapse; font-size: 12px; }
.cell { display: flex; gap: 6px; align-items: center; }
.people th, .people td { text-align: left; padding: 8px 24px; border-top: 1px solid #edf0eb; }
.missing td:first-child { font-weight: 600; }
.muted { color: var(--muted); }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
