<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'

/**
 * The job's hiring manager (0100). They alone see this job's candidates when
 * they hold the Hiring Manager access, and they make the contact call at
 * Screening. Whoever may edit the job names them; others read the name.
 */
const props = defineProps<{
  jobId: string
  companyId: string
  hiringManagerId: string | null
  hiringManagerName: string | null
  canEdit: boolean
}>()
const emit = defineEmits<{ changed: [] }>()

const options = ref<{ id: string; full_name: string }[]>([])
const picked = ref(props.hiringManagerId ?? '')
const saving = ref(false)
const error = ref<string | null>(null)

watch(
  () => props.hiringManagerId,
  (id) => (picked.value = id ?? ''),
)

async function loadOptions(): Promise<void> {
  const { data, error: err } = await supabase.rpc('hiring_managers', { p_company_id: props.companyId })
  if (err) {
    console.error('hiring_managers failed:', err.message)
    error.value = 'Could not load who can be hiring manager.'
    return
  }
  options.value = data ?? []
}

async function save(): Promise<void> {
  const next = picked.value || null
  if (next === props.hiringManagerId) return
  saving.value = true
  error.value = null
  const { error: err } = await supabase.from('jobs').update({ hiring_manager_id: next }).eq('id', props.jobId)
  saving.value = false
  if (err) {
    console.error('Setting the hiring manager failed:', err.message)
    error.value = friendlyRecruitmentError(err.message)
    picked.value = props.hiringManagerId ?? ''
    return
  }
  emit('changed')
}

onMounted(() => {
  if (props.canEdit) void loadOptions()
})
</script>

<template>
  <span class="hm-field">
    <template v-if="canEdit">
      <label for="job-hm">Hiring manager:</label>
      <select id="job-hm" v-model="picked" :disabled="saving" data-testid="job-hiring-manager" @change="save">
        <option value="">Not assigned</option>
        <option v-if="hiringManagerId && !options.some((o) => o.id === hiringManagerId)" :value="hiringManagerId">
          {{ hiringManagerName ?? 'Current hiring manager' }}
        </option>
        <option v-for="o in options" :key="o.id" :value="o.id">{{ o.full_name }}</option>
      </select>
    </template>
    <template v-else>Hiring manager: {{ hiringManagerName ?? 'Not assigned' }}</template>
    <span v-if="error" class="error" role="alert"> {{ error }}</span>
  </span>
</template>

<style scoped>
.hm-field { display: inline-flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.error { color: var(--red, #b42318); }
</style>
