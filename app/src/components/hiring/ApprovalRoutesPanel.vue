<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import {
  DEFAULT_ROUTE,
  MAX_STEPS,
  ROUTE_KINDS,
  STEP_CAPABILITIES,
  moveStep,
  routeRows,
  type RouteKind,
  type StepDraft,
} from '@/lib/approvalRoutes'

/**
 * Who approves, in what order, per company (0104; spec 9.13). Saving replaces
 * the company's route for that kind; an empty route falls back to the default
 * shown. Admins and people who manage the company's access may edit.
 */
const auth = useAuthStore()
const companies = ref<{ id: string; name: string }[]>([])
const people = ref<{ id: string; full_name: string }[]>([])
const companyId = ref('')
const kind = ref<RouteKind>('request')
const steps = ref<StepDraft[]>([])
const saved = ref<string>('[]')
const loading = ref(false)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const dirty = computed(() => JSON.stringify(steps.value) !== saved.value)

async function loadReference(): Promise<void> {
  const [co, pe] = await Promise.all([
    supabase.from('companies').select('id, name').is('archived_at', null).order('name'),
    supabase.from('people').select('id, full_name').is('archived_at', null).order('full_name'),
  ])
  if (co.error || pe.error) {
    error.value = 'Could not load companies and people.'
    return
  }
  companies.value = (co.data ?? []).filter((c) => auth.isAdmin || auth.can(c.id, 'access.manage'))
  people.value = pe.data ?? []
  companyId.value = companies.value[0]?.id ?? ''
}

async function loadRoute(): Promise<void> {
  if (!companyId.value) return
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('approval_routes')
    .select('position, label, approver_id, capability')
    .eq('company_id', companyId.value)
    .eq('kind', kind.value)
    .order('position')
  loading.value = false
  if (err) {
    console.error('Approval route load failed:', err.message)
    error.value = 'Could not load the route.'
    return
  }
  steps.value = (data ?? []).map((r) => ({ label: r.label, approverId: r.approver_id ?? '', capability: r.capability ?? '' }))
  saved.value = JSON.stringify(steps.value)
}

function addStep(): void {
  steps.value = [...steps.value, { label: '', approverId: '', capability: 'offer.approve' }]
}
function removeStep(i: number): void {
  steps.value = steps.value.filter((_, j) => j !== i)
}
function update(i: number, patch: Partial<StepDraft>): void {
  steps.value = steps.value.map((s, j) => (j === i ? { ...s, ...patch } : s))
}

async function save(): Promise<void> {
  const built = routeRows(companyId.value, kind.value, steps.value)
  if (built.rows === null) {
    error.value = built.error
    return
  }
  const rows = built.rows
  busy.value = true
  error.value = null
  notice.value = null
  const del = await supabase.from('approval_routes').delete().eq('company_id', companyId.value).eq('kind', kind.value)
  const ins = del.error || !rows.length ? { error: del.error } : await supabase.from('approval_routes').insert(rows)
  busy.value = false
  if (ins.error) {
    console.error('Saving the route failed:', ins.error.message)
    error.value = /row-level security/.test(ins.error.message) ? 'You need to manage this company’s access to change its route.' : ins.error.message
    await loadRoute()
    return
  }
  notice.value = rows.length ? 'Route saved. New submissions follow it.' : 'Route cleared — the default applies again.'
  await loadRoute()
}

watch([companyId, kind], () => {
  notice.value = null
  void loadRoute()
})
onMounted(async () => {
  await loadReference()
  await loadRoute()
})
</script>

<template>
  <div class="card routes">
    <div class="card-head">
      <div>
        <h2>Approval routes</h2>
        <p>Who approves, in order. A step names a person, or anyone in a group. A named person on leave is covered by their delegate.</p>
      </div>
    </div>
    <div class="card-body">
    <div class="filters">
      <label for="route-company">Company</label>
      <select id="route-company" v-model="companyId">
        <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
      </select>
      <label for="route-kind">Route for</label>
      <select id="route-kind" v-model="kind">
        <option v-for="k in ROUTE_KINDS" :key="k.value" :value="k.value">{{ k.label }}</option>
      </select>
    </div>
    <p v-if="!companies.length" class="empty">You do not manage access in any company.</p>
    <template v-else>
      <p v-if="!loading && !steps.length" class="default" data-testid="route-default">Default in use: {{ DEFAULT_ROUTE[kind] }}</p>
      <ol class="steps">
        <li v-for="(s, i) in steps" :key="i" class="step">
          <input :id="`route-label-${i}`" :value="s.label" maxlength="80" placeholder="Step name, e.g. Finance" aria-label="Step name" @input="update(i, { label: ($event.target as HTMLInputElement).value })" />
          <select :id="`route-person-${i}`" :value="s.approverId" aria-label="Person" @change="update(i, { approverId: ($event.target as HTMLSelectElement).value })">
            <option value="">A group (pick on the right)</option>
            <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
          </select>
          <select :id="`route-group-${i}`" :value="s.capability" :disabled="!!s.approverId" aria-label="Group" @change="update(i, { capability: ($event.target as HTMLSelectElement).value })">
            <option v-for="c in STEP_CAPABILITIES" :key="c.value" :value="c.value">{{ c.label }}</option>
          </select>
          <div class="step-actions">
            <button class="button secondary small-btn" type="button" :disabled="i === 0" aria-label="Move up" @click="steps = moveStep(steps, i, -1)">↑</button>
            <button class="button secondary small-btn" type="button" :disabled="i === steps.length - 1" aria-label="Move down" @click="steps = moveStep(steps, i, 1)">↓</button>
            <button class="button secondary small-btn danger-text" type="button" @click="removeStep(i)">Remove</button>
          </div>
        </li>
      </ol>
      <div class="actions">
        <button class="button secondary small-btn" type="button" :disabled="steps.length >= MAX_STEPS" @click="addStep">Add step</button>
        <button class="button small-btn" type="button" :disabled="busy || !dirty" data-testid="route-save" @click="save">{{ busy ? 'Saving…' : 'Save route' }}</button>
      </div>
      <p class="hint">Requests and offers already in approval keep the route they started with.</p>
    </template>
    <p v-if="notice" class="notice" role="status">{{ notice }}</p>
    <p v-if="error" class="error" role="alert">{{ error }}</p>
    </div>
  </div>
</template>

<style scoped>
.routes { display: grid; gap: 12px; }
.filters { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.steps { margin: 0; padding-left: 20px; display: grid; gap: 8px; }
.step { display: grid; grid-template-columns: minmax(120px, 1fr) minmax(140px, 1fr) minmax(160px, 1.3fr) auto; gap: 6px; align-items: center; }
.step input, .step select { min-width: 0; }
.step-actions, .actions { display: flex; gap: 6px; flex-wrap: wrap; }
.default, .hint { margin: 0; color: var(--muted); font-size: 12px; }
.notice, .error { margin: 0; }
.error { color: var(--red, #b42318); }
@media (max-width: 720px) { .step { grid-template-columns: 1fr; } }
</style>
