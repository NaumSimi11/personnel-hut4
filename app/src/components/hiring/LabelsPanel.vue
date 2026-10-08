<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import {
  KEY_PATTERN,
  MAX_LABEL_LENGTH,
  type LookupRow,
  type SubStatusGroup,
  type SubStatusRow,
  canRetire,
  duplicateLabel,
  groupByStage,
  keyFromLabel,
  labelChanged,
  nextSortOrder,
  normaliseLabel,
  validateLabel,
} from '@/lib/hiringLabels'

/**
 * Renaming the hiring vocabulary (task.md: HR is used to her own names, from
 * the years of Zoho Recruit before this app). A label changes; a key stays,
 * because the Zoho status map and the applications point at it. Since plan
 * 068 an admin also adds a status at any stage — usable the moment it is
 * saved — and retires one instead of deleting it, so applications that
 * already carry it keep reading it.
 *
 * Admins only: both lookups carry an `admin_write` policy, so a non-admin's
 * write is refused by the database rather than by this panel.
 */

type Table = 'application_sub_statuses' | 'candidate_sources'

const subStatuses = ref<SubStatusRow[]>([])
const sources = ref<LookupRow[]>([])
const drafts = ref<Record<string, string>>({})
const newLabels = ref<Record<string, string>>({})
const loaded = ref(false)
const savingId = ref<string | null>(null)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const groups = computed(() => groupByStage(subStatuses.value))

function idOf(table: string, key: string): string {
  return `${table}:${key}`
}
function draftOf(table: Table, row: LookupRow): string {
  return drafts.value[idOf(table, row.key)] ?? row.label
}
function setDraft(table: Table, row: LookupRow, value: string): void {
  drafts.value = { ...drafts.value, [idOf(table, row.key)]: value }
}
function isDirty(table: Table, row: LookupRow): boolean {
  return labelChanged(row.label, draftOf(table, row))
}
function stageRows(stageKey: string): SubStatusRow[] {
  return subStatuses.value.filter((r) => r.stage_key === stageKey)
}
function problemOf(table: Table, row: LookupRow): string | null {
  if (!isDirty(table, row)) return null
  const draft = draftOf(table, row)
  if (table === 'candidate_sources') return validateLabel(draft)
  return validateLabel(draft) ?? duplicateLabel(draft, stageRows((row as SubStatusRow).stage_key), row.key)
}
function addDraft(group: SubStatusGroup): string {
  return newLabels.value[group.stageKey] ?? ''
}
function addProblem(group: SubStatusGroup): string | null {
  const draft = addDraft(group)
  if (!draft.trim()) return null
  return validateLabel(draft) ?? duplicateLabel(draft, stageRows(group.stageKey))
}

// The database's refusals, in the panel's words; anything else is shown as it came.
function writeError(message: string, refusal: string): string {
  if (message.includes('row-level security')) return refusal
  if (message.includes('application_sub_statuses_label_per_stage')) return 'That name is already a status at this stage.'
  if (message.includes('application_sub_statuses_pkey')) return 'Someone added that status a moment ago. Reload the page to see it.'
  if (message.includes('application_sub_statuses_rule_keys_stay')) return 'The pipeline\'s own rules use this status, so it can be renamed but not retired.'
  if (message.includes('application_sub_statuses_key_check')) return 'That name cannot be made into a status key. Try a name with Latin letters.'
  return message
}

async function load(): Promise<void> {
  error.value = null
  const [subs, srcs] = await Promise.all([
    supabase.from('application_sub_statuses').select('key, stage_key, label, sort_order, archived_at'),
    supabase.from('candidate_sources').select('key, label, sort_order').is('archived_at', null),
  ])
  if (subs.error || srcs.error) {
    error.value = 'Could not load the hiring labels.'
    console.error('Hiring labels load failed:', subs.error?.message ?? srcs.error?.message)
    loaded.value = true
    return
  }
  subStatuses.value = (subs.data ?? []) as SubStatusRow[]
  sources.value = ((srcs.data ?? []) as LookupRow[]).sort((a, b) => a.sort_order - b.sort_order || a.key.localeCompare(b.key))
  drafts.value = {}
  loaded.value = true
}

function startWrite(id: string): void {
  error.value = null
  notice.value = null
  savingId.value = id
}

async function save(table: Table, row: LookupRow): Promise<void> {
  const id = idOf(table, row.key)
  const next = normaliseLabel(draftOf(table, row))
  const problem = problemOf(table, row)
  if (problem) {
    error.value = problem
    return
  }
  startWrite(id)
  const { error: err } = await supabase.from(table).update({ label: next }).eq('key', row.key)
  savingId.value = null
  if (err) {
    error.value = writeError(err.message, 'Only platform admins rename hiring labels.')
    return
  }
  if (table === 'application_sub_statuses') {
    subStatuses.value = subStatuses.value.map((r) => (r.key === row.key ? { ...r, label: next } : r))
  } else {
    sources.value = sources.value.map((r) => (r.key === row.key ? { ...r, label: next } : r))
  }
  drafts.value = { ...drafts.value, [id]: next }
  notice.value = `Renamed “${row.label}” to “${next}”. Everyone sees the new name from their next page load.`
}

function reset(table: Table, row: LookupRow): void {
  drafts.value = { ...drafts.value, [idOf(table, row.key)]: row.label }
}

async function add(group: SubStatusGroup): Promise<void> {
  const label = normaliseLabel(addDraft(group))
  const problem = validateLabel(label) ?? duplicateLabel(label, stageRows(group.stageKey))
  if (problem) {
    error.value = problem
    return
  }
  const key = keyFromLabel(label, new Set(subStatuses.value.map((r) => r.key)))
  if (!KEY_PATTERN.test(key)) {
    error.value = 'That name cannot be made into a status key. Try a name with Latin letters.'
    console.error('Status key out of pattern:', key)
    return
  }
  const row: SubStatusRow = {
    key,
    stage_key: group.stageKey,
    label,
    sort_order: nextSortOrder(stageRows(group.stageKey)),
    archived_at: null,
  }
  startWrite(`add:${group.stageKey}`)
  const { error: err } = await supabase.from('application_sub_statuses').insert(row)
  savingId.value = null
  if (err) {
    error.value = writeError(err.message, 'Only platform admins add hiring statuses.')
    return
  }
  subStatuses.value = [...subStatuses.value, row]
  newLabels.value = { ...newLabels.value, [group.stageKey]: '' }
  notice.value = `Added “${label}” to ${group.stageLabel}. It can be picked from the next page load.`
}

async function setRetired(row: SubStatusRow, retire: boolean): Promise<void> {
  if (!retire) {
    const clash = duplicateLabel(row.label, stageRows(row.stage_key), row.key)
    if (clash) {
      error.value = `${clash} Rename that one first.`
      return
    }
  }
  const archivedAt = retire ? new Date().toISOString() : null
  startWrite(idOf('application_sub_statuses', row.key))
  const { error: err } = await supabase.from('application_sub_statuses').update({ archived_at: archivedAt }).eq('key', row.key)
  savingId.value = null
  if (err) {
    error.value = writeError(err.message, 'Only platform admins retire hiring statuses.')
    return
  }
  subStatuses.value = subStatuses.value.map((r) => (r.key === row.key ? { ...r, archived_at: archivedAt } : r))
  notice.value = retire
    ? `Retired “${row.label}”. Applications that have it keep it; nobody can pick it any more.`
    : `Restored “${row.label}”. It can be picked again.`
}

onMounted(load)
</script>

<template>
  <div data-testid="hiring-labels-panel">
    <p class="hint">
      Name the statuses of every stage and the sources in your team's own words, add the ones you are missing,
      and retire the ones nobody uses. A rename changes only the wording — reports, filters and the Zoho import
      keep working, because they match on the key beside each name, never on the name. A retired status stays on
      the applications that have it.
    </p>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <p v-if="!loaded" class="hint">Loading…</p>

    <template v-if="loaded">
      <section v-for="group in groups" :key="group.stageKey" class="card" :data-testid="`label-stage-${group.stageKey}`">
        <div class="card-body">
          <div class="eyebrow">Statuses</div>
          <h2>{{ group.stageLabel }} stage</h2>
          <p v-if="!group.rows.length" class="hint">No statuses yet.</p>
          <div v-for="row in group.rows" :key="row.key" class="row" :data-testid="`label-row-${row.key}`">
            <code class="key">{{ row.key }}</code>
            <input
              class="input"
              type="text"
              :value="draftOf('application_sub_statuses', row)"
              :maxlength="MAX_LABEL_LENGTH"
              :aria-label="`Label for ${row.key}`"
              @input="setDraft('application_sub_statuses', row, ($event.target as HTMLInputElement).value)"
            />
            <div class="row-actions">
              <small v-if="problemOf('application_sub_statuses', row)" class="problem">
                {{ problemOf('application_sub_statuses', row) }}
              </small>
              <template v-if="isDirty('application_sub_statuses', row)">
                <button
                  class="button"
                  type="button"
                  :disabled="savingId !== null || !!problemOf('application_sub_statuses', row)"
                  :data-testid="`label-save-${row.key}`"
                  @click="save('application_sub_statuses', row)"
                >
                  {{ savingId === `application_sub_statuses:${row.key}` ? 'Saving…' : 'Save' }}
                </button>
                <button class="button secondary" type="button" :disabled="savingId !== null" @click="reset('application_sub_statuses', row)">
                  Cancel
                </button>
              </template>
              <button
                v-else-if="canRetire(row.key)"
                class="button secondary"
                type="button"
                :disabled="savingId !== null"
                :data-testid="`label-retire-${row.key}`"
                @click="setRetired(row, true)"
              >
                Retire
              </button>
              <small v-else class="kept" title="New's defaults and the &quot;not responding&quot; count use this status.">
                Used by the rules
              </small>
            </div>
          </div>
          <form class="row add-row" novalidate @submit.prevent="add(group)">
            <span class="key">New status</span>
            <input
              class="input"
              type="text"
              :value="addDraft(group)"
              :maxlength="MAX_LABEL_LENGTH"
              :placeholder="`Add a status at ${group.stageLabel}`"
              :aria-label="`New status at ${group.stageLabel}`"
              :data-testid="`label-add-input-${group.stageKey}`"
              @input="newLabels = { ...newLabels, [group.stageKey]: ($event.target as HTMLInputElement).value }"
            />
            <div class="row-actions">
              <small v-if="addProblem(group)" class="problem">{{ addProblem(group) }}</small>
              <button
                class="button"
                type="submit"
                :disabled="savingId !== null || !addDraft(group).trim() || !!addProblem(group)"
                :data-testid="`label-add-${group.stageKey}`"
              >
                {{ savingId === `add:${group.stageKey}` ? 'Adding…' : 'Add' }}
              </button>
            </div>
          </form>
          <details v-if="group.retired.length" class="retired">
            <summary>Retired ({{ group.retired.length }})</summary>
            <div v-for="row in group.retired" :key="row.key" class="row" :data-testid="`label-retired-${row.key}`">
              <code class="key">{{ row.key }}</code>
              <span class="retired-label">{{ row.label }}</span>
              <div class="row-actions">
                <button
                  class="button secondary"
                  type="button"
                  :disabled="savingId !== null"
                  :data-testid="`label-restore-${row.key}`"
                  @click="setRetired(row, false)"
                >
                  Restore
                </button>
              </div>
            </div>
          </details>
        </div>
      </section>

      <section class="card">
        <div class="card-body">
          <div class="eyebrow">Where candidates come from</div>
          <h2>Sources</h2>
          <div v-for="row in sources" :key="row.key" class="row" :data-testid="`label-row-${row.key}`">
            <code class="key">{{ row.key }}</code>
            <input
              class="input"
              type="text"
              :value="draftOf('candidate_sources', row)"
              :maxlength="MAX_LABEL_LENGTH"
              :aria-label="`Label for ${row.key}`"
              @input="setDraft('candidate_sources', row, ($event.target as HTMLInputElement).value)"
            />
            <div class="row-actions">
              <small v-if="problemOf('candidate_sources', row)" class="problem">{{ problemOf('candidate_sources', row) }}</small>
              <template v-if="isDirty('candidate_sources', row)">
                <button
                  class="button"
                  type="button"
                  :disabled="savingId !== null || !!problemOf('candidate_sources', row)"
                  :data-testid="`label-save-${row.key}`"
                  @click="save('candidate_sources', row)"
                >
                  {{ savingId === `candidate_sources:${row.key}` ? 'Saving…' : 'Save' }}
                </button>
                <button class="button secondary" type="button" :disabled="savingId !== null" @click="reset('candidate_sources', row)">
                  Cancel
                </button>
              </template>
            </div>
          </div>
        </div>
      </section>
    </template>
  </div>
</template>

<style scoped>
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin: 0 0 14px; max-width: 70ch; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin: 0 0 12px; }
.card { margin-bottom: 14px; }
h2 { margin: 0 0 12px; font-size: 15px; }
.row { display: flex; align-items: center; gap: 12px; padding: 8px 0; border-top: 1px solid var(--line); flex-wrap: wrap; }
.row:first-of-type { border-top: 0; }
.key { font-size: 11px; color: var(--muted); min-width: 170px; }
.input { flex: 1 1 220px; min-width: 0; }
.row-actions { display: flex; align-items: center; gap: 8px; }
.problem { font-size: 11px; color: var(--danger, #b3261e); }
.add-row { margin: 0; }
.kept { font-size: 11px; color: var(--muted); }
.retired { margin-top: 10px; font-size: 12px; color: var(--muted); }
.retired summary { cursor: pointer; padding: 6px 0; }
.retired-label { flex: 1 1 220px; min-width: 0; text-decoration: line-through; }
</style>
