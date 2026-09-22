<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import {
  MAX_LABEL_LENGTH,
  type LookupRow,
  type SubStatusRow,
  groupByStage,
  labelChanged,
  normaliseLabel,
  validateLabel,
} from '@/lib/hiringLabels'

/**
 * Renaming the hiring vocabulary (task.md: HR is used to her own names, from
 * the years of Zoho Recruit before this app). Only labels change — the keys
 * stay, because the Zoho status map and `applications.source_key` join on them.
 *
 * Admins only: both lookups carry an `admin_write` policy, so a non-admin's
 * save is refused by the database rather than by this panel.
 */

const subStatuses = ref<SubStatusRow[]>([])
const sources = ref<LookupRow[]>([])
const drafts = ref<Record<string, string>>({})
const loaded = ref(false)
const savingId = ref<string | null>(null)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const groups = computed(() => groupByStage(subStatuses.value))

function idOf(table: string, key: string): string {
  return `${table}:${key}`
}
function draftOf(table: string, row: LookupRow): string {
  return drafts.value[idOf(table, row.key)] ?? row.label
}
function setDraft(table: string, row: LookupRow, value: string): void {
  drafts.value = { ...drafts.value, [idOf(table, row.key)]: value }
}
function isDirty(table: string, row: LookupRow): boolean {
  return labelChanged(row.label, draftOf(table, row))
}
function problemOf(table: string, row: LookupRow): string | null {
  return isDirty(table, row) ? validateLabel(draftOf(table, row)) : null
}

async function load(): Promise<void> {
  error.value = null
  const [subs, srcs] = await Promise.all([
    supabase.from('application_sub_statuses').select('key, stage_key, label, sort_order').is('archived_at', null),
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

async function save(table: 'application_sub_statuses' | 'candidate_sources', row: LookupRow): Promise<void> {
  const id = idOf(table, row.key)
  const next = normaliseLabel(draftOf(table, row))
  const problem = validateLabel(next)
  if (problem) {
    error.value = problem
    return
  }
  error.value = null
  notice.value = null
  savingId.value = id
  const { error: err } = await supabase.from(table).update({ label: next }).eq('key', row.key)
  savingId.value = null
  if (err) {
    error.value = err.message.includes('row-level security')
      ? 'Only platform admins rename hiring labels.'
      : err.message
    return
  }
  const was = row.label
  row.label = next
  drafts.value = { ...drafts.value, [id]: next }
  notice.value = `Renamed “${was}” to “${next}”. Everyone sees the new name from their next page load.`
}

function reset(table: string, row: LookupRow): void {
  drafts.value = { ...drafts.value, [idOf(table, row.key)]: row.label }
}

onMounted(load)
</script>

<template>
  <div data-testid="hiring-labels-panel">
    <p class="hint">
      Rename what the pipeline calls each sub-status and each source, so the words match how your team already
      talks. Only the wording changes — reports, filters and the Zoho import keep working, because they match on
      the key beside each name, never on the name.
    </p>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <p v-if="!loaded" class="hint">Loading…</p>

    <template v-if="loaded">
      <section v-for="group in groups" :key="group.stageKey" class="card">
        <div class="card-body">
          <div class="eyebrow">Sub-statuses</div>
          <h2>{{ group.stageLabel }} stage</h2>
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
            </div>
          </div>
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
</style>
