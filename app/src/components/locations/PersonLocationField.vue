<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { loadCompanyStructure } from '@/lib/companyStructure'
import { locationName } from '@/lib/employeeLocations'
import LocationInput from '@/components/locations/LocationInput.vue'

/**
 * The person's location on their profile (25 Nov): typed in by HR or an
 * admin, right here; flagged when it is missing.
 */
const props = defineProps<{
  period: { id: string; company_id: string; status: string; location: { name: string } | null }
}>()
const emit = defineEmits<{ saved: [] }>()

const auth = useAuthStore()
const editing = ref(false)
const value = ref(props.period.location?.name ?? '')
const suggestions = ref<string[]>([])
const busy = ref(false)
const error = ref<string | null>(null)

const canEdit = computed(
  () => ['active', 'pre_start'].includes(props.period.status) && auth.can(props.period.company_id, 'employment.edit'),
)
const missing = computed(() => !props.period.location)

watch(
  () => props.period.location?.name,
  (name) => (value.value = name ?? ''),
)

async function start(): Promise<void> {
  editing.value = true
  error.value = null
  try {
    suggestions.value = (await loadCompanyStructure(props.period.company_id)).locations.map((l) => l.name)
  } catch {
    suggestions.value = []
  }
}

async function save(): Promise<void> {
  const parsed = locationName.safeParse(value.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the location.'
    return
  }
  busy.value = true
  error.value = null
  const { error: err } = await supabase.rpc('set_employment_location_name', { p_period_id: props.period.id, p_name: parsed.data })
  busy.value = false
  if (err) {
    error.value = err.message || 'Could not save the location.'
    console.error('set_employment_location_name failed:', err.message)
    return
  }
  editing.value = false
  emit('saved')
}
</script>

<template>
  <div v-if="missing || canEdit" class="location-field" :class="{ missing }" data-testid="person-location">
    <template v-if="!editing">
      <span>
        <strong>Location:</strong>
        {{ period.location?.name ?? 'Not set' }}
      </span>
      <button v-if="canEdit" type="button" class="button small-btn" :class="{ secondary: !missing }" data-testid="person-location-edit" @click="start">
        {{ missing ? 'Add location' : 'Change' }}
      </button>
    </template>
    <template v-else>
      <label :for="`loc-${period.id}`"><strong>Location</strong></label>
      <LocationInput :id="`loc-${period.id}`" v-model="value" :suggestions="suggestions" aria-label="Location" @commit="save" />
      <button type="button" class="button small-btn" :disabled="busy" data-testid="person-location-save" @click="save">{{ busy ? 'Saving…' : 'Save' }}</button>
      <button type="button" class="button secondary small-btn" @click="editing = false">Cancel</button>
    </template>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
  </div>
</template>

<style scoped>
.location-field { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; padding: 10px 16px; border-top: 1px solid var(--line); font-size: 12px; background: #fff; }
.location-field.missing { background: #fdf6e7; }
.location-field .error-note { width: 100%; margin: 0; }
.small-btn { font-size: 11px; padding: 6px 10px; }
</style>
