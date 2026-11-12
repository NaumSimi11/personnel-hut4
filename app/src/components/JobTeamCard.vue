<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'

/**
 * The opening's positions and hiring team (0107; spec 2.4, 3.2). Positions
 * are counted from the approved headcount and the hires. Team members see
 * the job's candidates the way its hiring manager does and can score its
 * interviews; whoever may edit the job adds and removes them.
 */
const props = defineProps<{ jobId: string; canEdit: boolean }>()

const ROLES = [
  { value: 'recruiter', label: 'Recruiter' },
  { value: 'interviewer', label: 'Interviewer' },
  { value: 'assessor', label: 'Assessor' },
  { value: 'panel', label: 'Panel' },
  { value: 'director', label: 'Director / CEO' },
] as const
type Role = (typeof ROLES)[number]['value']
type Member = { person_id: string; role: Role; person: { full_name: string } | null }

const positions = ref<{ headcount: number; filled: number; open: number } | null>(null)
const team = ref<Member[]>([])
const people = ref<{ id: string; full_name: string }[]>([])
const pickPerson = ref('')
const pickRole = ref<Role>('interviewer')
const busy = ref(false)
const error = ref<string | null>(null)

const candidates = computed(() => people.value.filter((p) => !team.value.some((m) => m.person_id === p.id)))
const roleLabel = (r: Role) => ROLES.find((x) => x.value === r)?.label ?? r

async function load(): Promise<void> {
  error.value = null
  const [pos, members, list] = await Promise.all([
    supabase.rpc('job_positions', { p_job_ids: [props.jobId] }),
    supabase.from('job_team').select('person_id, role, person:people!job_team_person_id_fkey(full_name)').eq('job_id', props.jobId),
    props.canEdit ? supabase.from('people').select('id, full_name').is('archived_at', null).order('full_name') : Promise.resolve({ data: [], error: null }),
  ])
  if (pos.error || members.error) {
    console.error('Team load failed:', pos.error?.message ?? members.error?.message)
    error.value = 'Could not load the positions and team.'
    return
  }
  positions.value = ((pos.data ?? []) as { headcount: number; filled: number; open: number }[])[0] ?? null
  team.value = (members.data ?? []) as unknown as Member[]
  people.value = list.data ?? []
}

async function add(): Promise<void> {
  if (!pickPerson.value) return
  busy.value = true
  error.value = null
  const { error: err } = await supabase.from('job_team').insert({ job_id: props.jobId, person_id: pickPerson.value, role: pickRole.value })
  busy.value = false
  if (err) {
    console.error('Adding to the team failed:', err.message)
    error.value = /row-level security/.test(err.message) ? 'Adding to the team needs "Edit job descriptions" here.' : err.message
    return
  }
  pickPerson.value = ''
  await load()
}

async function remove(m: Member): Promise<void> {
  busy.value = true
  error.value = null
  const { error: err } = await supabase.from('job_team').delete().eq('job_id', props.jobId).eq('person_id', m.person_id)
  busy.value = false
  if (err) {
    console.error('Removing from the team failed:', err.message)
    error.value = err.message
    return
  }
  await load()
}

onMounted(load)
</script>

<template>
  <div class="card team-card" data-testid="job-team">
    <div class="card-head">
      <div>
        <h2>Positions and hiring team</h2>
        <p v-if="positions">{{ positions.open }} of {{ positions.headcount }} position{{ positions.headcount === 1 ? '' : 's' }} open · {{ positions.filled }} filled</p>
      </div>
    </div>
    <div class="card-body">
    <ul v-if="team.length" class="team">
      <li v-for="m in team" :key="m.person_id">
        <span>{{ m.person?.full_name ?? '—' }}</span>
        <small>{{ roleLabel(m.role) }}</small>
        <button v-if="canEdit" class="button secondary small-btn danger-text" type="button" :disabled="busy" @click="remove(m)">Remove</button>
      </li>
    </ul>
    <p v-else class="empty-line">Nobody on the hiring team yet. Team members see this job's candidates and score its interviews.</p>
    <form v-if="canEdit" class="add" @submit.prevent="add">
      <select id="team-person" v-model="pickPerson" aria-label="Person" :disabled="busy">
        <option value="">Add someone…</option>
        <option v-for="p in candidates" :key="p.id" :value="p.id">{{ p.full_name }}</option>
      </select>
      <select id="team-role" v-model="pickRole" aria-label="Role" :disabled="busy">
        <option v-for="r in ROLES" :key="r.value" :value="r.value">{{ r.label }}</option>
      </select>
      <button class="button small-btn" type="submit" :disabled="busy || !pickPerson">Add</button>
    </form>
    <p v-if="error" class="error" role="alert">{{ error }}</p>
    </div>
  </div>
</template>

<style scoped>
.team-card { display: grid; gap: 10px; }
.team { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.team li { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.team small { color: var(--muted); }
.add { display: flex; gap: 6px; flex-wrap: wrap; }
.empty-line { margin: 0; color: var(--muted); font-size: 12px; }
.error { margin: 0; color: var(--red, #b42318); }
</style>
