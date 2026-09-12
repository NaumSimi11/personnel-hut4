<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAccessCatalog } from '@/stores/accessCatalog'
import { diffSets, withDependencies, withoutDependents } from '@/lib/permissions'

const route = useRoute()
const router = useRouter()
const catalog = useAccessCatalog()

const personId = route.params.personId as string
const person = ref<{ full_name: string } | null>(null)
const companies = ref<{ id: string; name: string }[]>([])
const companyId = ref<string>('')

const grantId = ref<string | null>(null)
const selected = ref<Set<string>>(new Set())
const baseline = ref<Set<string>>(new Set())
const presetName = ref('No access')

const loading = ref(true)
const saving = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const dirty = computed(
  () =>
    selected.value.size !== baseline.value.size ||
    [...selected.value].some((k) => !baseline.value.has(k)),
)
const allowedLabels = computed(() =>
  [...selected.value].map((k) => catalog.labels[k] ?? k).sort(),
)
const warnings = computed(() => {
  const list: string[] = []
  if (!selected.value.has('salary.view')) list.push('Individual salaries remain hidden.')
  if (!selected.value.has('payroll.export')) list.push('Payroll export is not allowed.')
  if (!selected.value.has('access.manage')) list.push('Cannot change other people’s access.')
  return list
})

function groupCount(name: string): string {
  const group = catalog.groups.find((g) => g.name === name)
  if (!group) return ''
  const on = group.capabilities.filter((c) => selected.value.has(c.key)).length
  return `${on}/${group.capabilities.length}`
}

function toggle(key: string, on: boolean): void {
  selected.value = on
    ? withDependencies(selected.value, key, catalog.dependencies)
    : withoutDependents(selected.value, key, catalog.dependencies)
  presetName.value = 'Custom'
}

function applyPreset(name: string): void {
  presetName.value = name
  const preset = catalog.presets.find((p) => p.name === name)
  if (preset) selected.value = new Set(preset.capabilities)
}

// Switching company quickly can leave an earlier response landing after a
// later one; only the most recent request may write the grant.
let grantRequestSeq = 0

async function loadGrant(): Promise<void> {
  const seq = ++grantRequestSeq
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('access_grants')
    .select('id, source_preset_id, grant_capabilities(capability_key)')
    .eq('person_id', personId)
    .eq('company_id', companyId.value)
    .maybeSingle()
  if (seq !== grantRequestSeq) return
  if (err) {
    error.value = 'Could not load this grant.'
    console.error('Grant load failed:', err.message)
  } else {
    grantId.value = data?.id ?? null
    const keys = (data?.grant_capabilities ?? []).map((c) => c.capability_key)
    selected.value = new Set(keys)
    baseline.value = new Set(keys)
    const sourcePreset = catalog.presets.find((p) => p.id === data?.source_preset_id)
    presetName.value = data ? (sourcePreset?.name ?? 'Custom') : 'No access'
  }
  loading.value = false
}

async function save(): Promise<void> {
  saving.value = true
  error.value = null
  notice.value = null
  try {
    const preset = catalog.presets.find((p) => p.name === presetName.value)
    const { data: grant, error: upsertErr } = await supabase
      .from('access_grants')
      .upsert(
        {
          person_id: personId,
          company_id: companyId.value,
          source_preset_id: preset?.id ?? null,
        },
        { onConflict: 'person_id,company_id' },
      )
      .select('id')
      .single()
    if (upsertErr) throw new Error(upsertErr.message)

    const { added, removed } = diffSets(baseline.value, selected.value)
    if (removed.length) {
      const { error: delErr } = await supabase
        .from('grant_capabilities')
        .delete()
        .eq('grant_id', grant.id)
        .in('capability_key', removed)
      if (delErr) throw new Error(delErr.message)
    }
    if (added.length) {
      const { error: insErr } = await supabase
        .from('grant_capabilities')
        .insert(added.map((key) => ({ grant_id: grant.id, capability_key: key })))
      if (insErr) throw new Error(insErr.message)
    }
    grantId.value = grant.id
    baseline.value = new Set(selected.value)
    notice.value = 'Permissions saved. Changes are recorded in the audit history.'
  } catch (e) {
    error.value = e instanceof Error ? `Save failed: ${e.message}` : 'Save failed.'
  } finally {
    saving.value = false
  }
}

// Switching company reloads the grant. Edits are disabled while it loads
// (see the preset select and checkboxes) so a slow response can never
// overwrite a change the person has already made.
watch(companyId, () => {
  if (companyId.value) loadGrant()
})

onMounted(async () => {
  await catalog.load()
  const [personRes, companiesRes] = await Promise.all([
    supabase.from('people').select('full_name').eq('id', personId).maybeSingle(),
    supabase.from('companies').select('id, name').is('archived_at', null).order('name'),
  ])
  if (personRes.error || !personRes.data) {
    error.value = 'Person not found or not visible with your access.'
    loading.value = false
    return
  }
  person.value = personRes.data
  companies.value = companiesRes.data ?? []
  companyId.value = (route.query.company as string) || companies.value[0]?.id || ''
})
</script>

<template>
  <div>
    <div class="eyebrow">Company access</div>
    <h1 v-if="person">Choose what {{ person.full_name.split(' ')[0] }} can do.</h1>
    <h1 v-else>Company access</h1>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>

    <div class="editor-grid">
      <div class="card">
        <div class="card-body">
          <div class="form-grid">
            <div class="field">
              <label for="company">Company access applies to</label>
              <select id="company" v-model="companyId">
                <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
              </select>
            </div>
            <div class="field">
              <label for="preset">Start from a preset</label>
              <select
                id="preset"
                :value="presetName"
                :disabled="loading"
                @change="applyPreset(($event.target as HTMLSelectElement).value)"
              >
                <option v-for="p in catalog.presets" :key="p.id" :value="p.name">
                  {{ p.name }}
                </option>
                <option value="Custom">Custom</option>
              </select>
            </div>
          </div>

          <p class="hint">
            Selecting an action also enables the viewing access it requires; removing a
            prerequisite removes what depends on it.
          </p>

          <div v-if="loading" class="empty">Loading grant…</div>
          <details
            v-for="(group, i) in catalog.groups"
            v-else
            :key="group.name"
            class="permission-group"
            :open="i < 2"
          >
            <summary>
              {{ group.name }}
              <span>{{ groupCount(group.name) }}</span>
            </summary>
            <label v-for="cap in group.capabilities" :key="cap.key" class="permission-check">
              <input
                type="checkbox"
                :checked="selected.has(cap.key)"
                :disabled="loading"
                @change="toggle(cap.key, ($event.target as HTMLInputElement).checked)"
              />
              <span>{{ cap.label }}</span>
              <small v-if="cap.sensitive">Sensitive</small>
            </label>
          </details>

          <div class="actions">
            <button class="button secondary" type="button" @click="router.back()">Back</button>
            <button class="button" type="button" :disabled="!dirty || saving" @click="save">
              {{ saving ? 'Saving…' : 'Save permissions' }}
            </button>
          </div>
        </div>
      </div>

      <aside class="card preview">
        <div class="card-body">
          <div class="eyebrow">Effective access preview</div>
          <h2 class="preview-title">
            {{ selected.size ? 'Allowed in this company' : 'No access to this company' }}
          </h2>
          <ul v-if="selected.size" class="preview-list">
            <li v-for="label in allowedLabels" :key="label">{{ label }}</li>
          </ul>
          <p v-else class="hint">This person has no capabilities granted here.</p>
          <div class="preview-warning">
            <p v-for="w in warnings" :key="w">{{ w }}</p>
            <p>Other companies keep their own separate grants.</p>
          </div>
        </div>
      </aside>
    </div>
  </div>
</template>

<style scoped>
h1 { margin-bottom: 24px; }
.editor-grid { display: grid; grid-template-columns: minmax(0, 1.5fr) minmax(260px, 1fr); gap: 22px; }
@media (max-width: 900px) { .editor-grid { grid-template-columns: 1fr; } }
.form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 20px; }
@media (max-width: 600px) { .form-grid { grid-template-columns: 1fr; } }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; }
.notice {
  display: block;
  padding: 12px 15px;
  border-radius: 9px;
  background: #edf5ed;
  color: #3e744e;
  font-size: 12px;
  margin-bottom: 16px;
}
.permission-group { border: 1px solid var(--line); border-radius: 9px; margin-bottom: 12px; overflow: hidden; }
.permission-group summary {
  padding: 14px;
  font-size: 12px;
  font-weight: 550;
  cursor: pointer;
  display: flex;
  justify-content: space-between;
  background: #fafbf8;
}
.permission-group summary span { color: var(--muted); font-size: 10px; font-weight: 400; }
.permission-check {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 14px;
  font-size: 11px;
  border-top: 1px solid #f1f3ee;
  cursor: pointer;
}
.permission-check input { accent-color: var(--green); width: 15px; height: 15px; }
.permission-check small { margin-left: auto; color: #9c8051; font-size: 9px; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 18px; }
.preview { background: #f5f7f1; align-self: start; }
.preview-title { font-size: 14px; margin: 12px 0; }
.preview-list { padding-left: 17px; font-size: 11px; line-height: 1.8; color: #566750; margin: 0 0 14px; }
.preview-warning {
  font-size: 10px;
  color: #8b7247;
  line-height: 1.6;
  padding-top: 12px;
  border-top: 1px solid #dfe7d6;
}
.preview-warning p { margin: 0 0 4px; }
</style>
