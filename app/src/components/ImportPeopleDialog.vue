<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import {
  IMPORT_TEMPLATE,
  parseCsv,
  parseImportResult,
  shapeRows,
  type ImportField,
  type ImportResult,
  type ImportRow,
} from '@/lib/importPeople'

/**
 * Import people from a CSV (plan 032): paste or upload, preview the
 * verdicts the database returns for every row, then import — the same
 * function with commit on, all rows or none.
 */

const props = defineProps<{ companies: { id: string; name: string }[] }>()
const emit = defineEmits<{ imported: [count: number] }>()

const auth = useAuthStore()
const dialog = ref<HTMLDialogElement | null>(null)
const companyId = ref('')
const csv = ref('')
const rows = ref<ImportRow[]>([])
const missing = ref<ImportField[]>([])
const ignored = ref<string[]>([])
const preview = ref<ImportResult | null>(null)
const previewedFor = ref('')
const done = ref<number | null>(null)
const busy = ref(false)
const error = ref<string | null>(null)

const allowed = computed(() => props.companies.filter((c) => auth.can(c.id, 'employment.edit')))
const canImport = computed(() => preview.value !== null && preview.value.refused === 0 && preview.value.ready > 0 && previewedFor.value === csv.value + companyId.value)

function open(): void {
  companyId.value = allowed.value[0]?.id ?? ''
  csv.value = ''
  rows.value = []
  missing.value = []
  ignored.value = []
  preview.value = null
  done.value = null
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

async function onFile(event: Event): Promise<void> {
  const file = (event.target as HTMLInputElement).files?.[0]
  if (!file) return
  csv.value = await file.text()
}

function downloadTemplate(): void {
  const blob = new Blob([IMPORT_TEMPLATE], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = 'people-import-template.csv'
  a.click()
  URL.revokeObjectURL(url)
}

async function run(commit: boolean): Promise<void> {
  error.value = null
  done.value = null
  const shaped = shapeRows(parseCsv(csv.value))
  rows.value = shaped.rows
  missing.value = shaped.missing
  ignored.value = shaped.ignored
  if (!companyId.value) {
    error.value = 'Choose the company.'
    return
  }
  if (shaped.missing.length) {
    error.value = `The file needs these columns: ${shaped.missing.join(', ')}.`
    preview.value = null
    return
  }
  if (!shaped.rows.length) {
    error.value = 'The file has no rows.'
    preview.value = null
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('import_people', {
    p_company_id: companyId.value,
    p_rows: shaped.rows,
    p_commit: commit,
  })
  busy.value = false
  if (err) {
    error.value = /employment\.edit/.test(err.message) ? 'You need employment.edit in this company to import people.' : err.message
    console.error('People import failed:', err.message)
    return
  }
  const result = parseImportResult(data)
  preview.value = result
  previewedFor.value = csv.value + companyId.value
  if (result.committed) {
    done.value = result.ready
    emit('imported', result.ready)
  }
}

function close(): void {
  dialog.value?.close()
}
</script>

<template>
  <dialog ref="dialog" class="import-dialog" aria-labelledby="import-title">
    <div class="body">
      <div class="eyebrow">People import</div>
      <h2 id="import-title">Bring a list of people in at once.</h2>
      <p class="hint">
        Columns: full_name, work_email, job_title, start_date (YYYY-MM-DD), and optionally employment_type_key,
        department, location, manager_email (someone in the file or already employed here), preferred_name, phone.
        Existing emails are refused, never merged.
        <button class="link" type="button" @click="downloadTemplate">Download a template</button>
      </p>

      <div class="grid">
        <div class="field">
          <label for="import-company">Company</label>
          <select id="import-company" v-model="companyId">
            <option v-for="c in allowed" :key="c.id" :value="c.id">{{ c.name }}</option>
          </select>
        </div>
        <div class="field">
          <label for="import-file">CSV file</label>
          <input id="import-file" type="file" accept=".csv,text/csv" @change="onFile" />
        </div>
      </div>
      <div class="field">
        <label for="import-csv">Or paste the CSV</label>
        <textarea id="import-csv" v-model="csv" rows="6" spellcheck="false"></textarea>
      </div>
      <p v-if="ignored.length" class="hint">Ignored columns: {{ ignored.join(', ') }}.</p>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <p v-if="done !== null" class="success-note" role="status">Imported {{ done }} {{ done === 1 ? 'person' : 'people' }}.</p>

      <div v-if="preview && done === null" class="preview">
        <div class="verdict-summary">
          {{ preview.ready }} ready · {{ preview.refused }} refused
          <template v-if="preview.refused"> — fix the file and preview again; nothing is imported until every row is ready.</template>
        </div>
        <div v-for="v in preview.rows" :key="v.row" class="verdict-row" :class="{ refused: !v.ok }">
          <span class="row-no">{{ v.row }}</span>
          <div class="row-text">
            <strong>{{ v.full_name || '—' }} <span class="muted">· {{ v.work_email || 'no email' }}</span></strong>
            <small>{{ v.ok ? 'Ready' : v.problems.join(' · ') }}</small>
          </div>
        </div>
      </div>

      <div class="actions">
        <button class="button secondary" type="button" @click="close">Close</button>
        <button v-if="done === null" class="button secondary" type="button" :disabled="busy" @click="run(false)">Preview</button>
        <button v-if="done === null" class="button" type="button" :disabled="busy || !canImport" @click="run(true)">
          Import {{ preview?.ready ?? 0 }} {{ (preview?.ready ?? 0) === 1 ? 'person' : 'people' }}
        </button>
      </div>
    </div>
  </dialog>
</template>

<style scoped>
.import-dialog { border: 0; border-radius: 15px; padding: 0; width: min(720px, calc(100vw - 36px)); box-shadow: 0 25px 100px #122f3038; color: var(--ink); }
.import-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 12px; }
.link { border: 0; background: none; color: var(--green); font-size: 11px; padding: 0; cursor: pointer; text-decoration: underline; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
textarea { width: 100%; font: 12px/1.5 ui-monospace, monospace; padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; resize: vertical; }
.preview { border: 1px solid var(--line); border-radius: 10px; margin: 12px 0; max-height: 300px; overflow: auto; }
.verdict-summary { padding: 10px 14px; font-size: 12px; font-weight: 600; background: #fafbf8; border-bottom: 1px solid var(--line); }
.verdict-row { display: flex; gap: 12px; padding: 8px 14px; border-top: 1px solid #edf0eb; }
.verdict-row.refused { background: #fbeaea; }
.row-no { font-size: 11px; color: var(--muted); min-width: 18px; padding-top: 2px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 2px; }
.muted { font-weight: 400; color: var(--muted); }
.success-note { font-size: 12px; color: #3e744e; background: #edf5ed; padding: 10px 14px; border-radius: 9px; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
</style>
