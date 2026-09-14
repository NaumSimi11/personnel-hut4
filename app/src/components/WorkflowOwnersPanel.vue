<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'

/**
 * Workflow owners (plan 024): who approvals are routed to in this company,
 * one row per workflow role. Writes are admin-only by RLS (0006) and
 * audited (0005). Saving "Unassigned" keeps the row with a NULL owner so the
 * audit trail records who cleared it.
 */
const props = defineProps<{ companyId: string }>()

type Role = { key: string; label: string }
type Person = { id: string; full_name: string; companies: string[] }
type OwnerRow = { role_key: string; person_id: string | null }

const loading = ref(true)
const error = ref<string | null>(null)
const roles = ref<Role[]>([])
const people = ref<Person[]>([])
const selection = ref<Record<string, string>>({})
const saved = ref<Record<string, string | null>>({})
const savingKey = ref<string | null>(null)
const savedKey = ref<string | null>(null)

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [rolesRes, ownersRes, peopleRes] = await Promise.all([
    supabase.from('workflow_roles').select('key, label').order('key'),
    supabase.from('workflow_owners').select('role_key, person_id').eq('company_id', props.companyId),
    // Everyone employed anywhere in the group: HR at the holding owns
    // workflows for every company, so the list is not scoped.
    supabase
      .from('employment_periods')
      .select('person:people!employment_periods_person_id_fkey(id, full_name), company:companies(name)')
      .in('status', ['active', 'pre_start']),
  ])
  loading.value = false
  if (rolesRes.error || ownersRes.error || peopleRes.error) {
    error.value = 'Could not load workflow owners.'
    console.error('Workflow owners load failed:', rolesRes.error?.message ?? ownersRes.error?.message ?? peopleRes.error?.message)
    return
  }
  roles.value = rolesRes.data ?? []
  const seen = new Map<string, Person>()
  for (const row of peopleRes.data ?? []) {
    const p = row.person as unknown as { id: string; full_name: string } | null
    const company = (row.company as unknown as { name: string } | null)?.name
    if (!p) continue
    const entry = seen.get(p.id) ?? { ...p, companies: [] }
    seen.set(p.id, { ...entry, companies: company && !entry.companies.includes(company) ? [...entry.companies, company] : entry.companies })
  }
  people.value = [...seen.values()].sort((a, b) => a.full_name.localeCompare(b.full_name))
  const owners = (ownersRes.data ?? []) as OwnerRow[]
  saved.value = Object.fromEntries(owners.map((o) => [o.role_key, o.person_id]))
  selection.value = Object.fromEntries(roles.value.map((r) => [r.key, saved.value[r.key] ?? '']))
}

function isDirty(roleKey: string): boolean {
  return (selection.value[roleKey] || null) !== (saved.value[roleKey] ?? null)
}

async function save(roleKey: string): Promise<void> {
  savingKey.value = roleKey
  savedKey.value = null
  error.value = null
  const personId = selection.value[roleKey] || null
  const { data, error: err } = await supabase
    .from('workflow_owners')
    .upsert({ company_id: props.companyId, role_key: roleKey, person_id: personId }, { onConflict: 'company_id,role_key' })
    .select('role_key, person_id')
    .maybeSingle()
  savingKey.value = null
  if (err || !data) {
    error.value = err ? 'Could not save the owner.' : 'Saving the owner needs platform admin access.'
    console.error('Workflow owner save failed:', err?.message ?? 'no row returned')
    return
  }
  saved.value = { ...saved.value, [roleKey]: data.person_id }
  savedKey.value = roleKey
}

onMounted(load)
watch(() => props.companyId, load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Workflow owners</h2>
        <p>Who approvals in this company are routed to. An unassigned role still requires approval — it is never skipped.</p>
      </div>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="error" class="error" role="alert">{{ error }}</div>
      <div v-for="role in roles" :key="role.key" class="owner-row">
        <div class="row-text">
          <strong>{{ role.label }}</strong>
          <small>{{ role.key }}</small>
        </div>
        <select v-model="selection[role.key]" :aria-label="role.label">
          <option value="">Unassigned</option>
          <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }} · {{ p.companies.join(', ') }}</option>
        </select>
        <button
          class="button secondary small-btn"
          :disabled="savingKey === role.key || !isDirty(role.key)"
          @click="save(role.key)"
        >
          Save
        </button>
        <span v-if="savedKey === role.key && !isDirty(role.key)" class="saved">Saved</span>
      </div>
    </template>
  </div>
</template>

<style scoped>
.owner-row { display: flex; align-items: center; gap: 12px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.row-text { flex: 1; min-width: 160px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; min-width: 180px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.saved { font-size: 11px; color: #3e744e; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
</style>
