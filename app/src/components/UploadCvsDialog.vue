<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import type { Json } from '@/types/database'
import { FILE_ACCEPT, candidateNameFromFile, validateApplicationFile } from '@/lib/applicationFiles'
import { uploadCandidateFile } from '@/lib/candidateFiles'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import { NOT_ATTACHABLE, matchHistoryLine, matchSentence, type CandidateMatch } from '@/lib/candidatePool'

/**
 * Twenty CVs on a laptop → twenty candidates in this job's pipeline. Drop
 * the files, correct the guessed names, save: each file goes through
 * upsert_sourced_candidate (an application at `new`) and the CV lands on the
 * candidate's record, where it follows the person to every job (plan 052).
 * Files are saved one by one so a bad file only fails its own row; a row the
 * database recognises as a possible duplicate waits, inline, for the person
 * to attach it or create a new record anyway — it never merges by itself.
 */
const props = defineProps<{ jobId: string; companyId: string }>()
const emit = defineEmits<{ created: [count: number] }>()

type RowState = 'ready' | 'saving' | 'duplicate' | 'done' | 'failed'
type Row = {
  file: File
  name: string
  email: string
  problem: string | null
  state: RowState
  matches: CandidateMatch[] | null
  attachTo: string | null
  ignoreMatches: boolean
}
type UpsertResult = {
  action: 'created' | 'attached' | 'updated' | 'matches'
  id: string | null
  application_id: string | null
  matches: CandidateMatch[]
}

const CV_NOT_UPLOADED = 'Candidate added, but the CV did not upload — attach it from their record.'

const auth = useAuthStore()
const dialog = ref<HTMLDialogElement | null>(null)
const fileInput = ref<HTMLInputElement | null>(null)
const rows = ref<Row[]>([])
const busy = ref(false)
const dragging = ref(false)

const ready = computed(() => rows.value.filter((r) => r.state === 'ready' && !r.problem && r.name.trim().length >= 2))
const done = computed(() => rows.value.filter((r) => r.state === 'done').length)

function open(): void {
  rows.value = []
  busy.value = false
  dialog.value?.showModal()
}
defineExpose({ open })

function addFiles(list: FileList | File[]): void {
  const added = Array.from(list).map((file) => ({
    file,
    name: candidateNameFromFile(file.name),
    email: '',
    problem: validateApplicationFile(file),
    state: 'ready' as const,
    matches: null,
    attachTo: null,
    ignoreMatches: false,
  }))
  rows.value = [...rows.value, ...added]
}

function onPick(event: Event): void {
  const input = event.target as HTMLInputElement
  if (input.files?.length) addFiles(input.files)
  input.value = ''
}

function onDrop(event: DragEvent): void {
  dragging.value = false
  if (event.dataTransfer?.files.length) addFiles(event.dataTransfer.files)
}

function removeRow(i: number): void {
  rows.value = rows.value.filter((_, idx) => idx !== i)
}

function setRow(i: number, patch: Partial<Row>): void {
  rows.value = rows.value.map((r, idx) => (idx === i ? { ...r, ...patch } : r))
}

/** "Also matched by row n" — the 1-based earlier row the same record was offered to. */
function alsoMatchedBy(i: number, matchId: string): number | null {
  const earlier = rows.value.findIndex((r, idx) => idx < i && (r.matches?.some((m) => m.id === matchId) ?? false))
  return earlier === -1 ? null : earlier + 1
}

async function saveOne(i: number): Promise<void> {
  const row = rows.value[i]
  if (!row) return
  setRow(i, { state: 'saving', problem: null })
  const payload = {
    full_name: row.name.trim(),
    email: row.email.trim().toLowerCase() || null,
    source_key: 'added_by_hand',
    job_id: props.jobId,
    ...(row.attachTo && { attach_to: row.attachTo }),
    ...(row.ignoreMatches && { ignore_matches: true }),
  }
  const { data, error: rpcErr } = await supabase.rpc('upsert_sourced_candidate', {
    p_provider: 'manual',
    p_ref: null,
    p: payload as Json,
  })
  if (rpcErr) {
    console.error('CV upload failed:', row.file.name, rpcErr.message)
    setRow(i, { state: 'failed', problem: friendlyRecruitmentError(rpcErr.message) })
    return
  }
  const result = data as UpsertResult
  if (result.action === 'matches') {
    setRow(i, { state: 'duplicate', matches: result.matches })
    return
  }
  if (!result.id) {
    setRow(i, { state: 'failed', problem: 'Could not save this candidate.' })
    return
  }
  try {
    await uploadCandidateFile({ candidateId: result.id, file: row.file, kind: 'cv', uploadedBy: auth.personId })
    setRow(i, { state: 'done' })
  } catch (e) {
    // The candidate and application stand; only the file is missing.
    console.error('CV upload failed:', row.file.name, e instanceof Error ? e.message : e)
    setRow(i, { state: 'failed', problem: CV_NOT_UPLOADED })
  }
}

/** A choice on a duplicate row is final: it re-runs the save at once. */
async function attach(i: number, candidateId: string): Promise<void> {
  setRow(i, { attachTo: candidateId, ignoreMatches: false })
  await saveOne(i)
  finish()
}

async function createNew(i: number): Promise<void> {
  setRow(i, { attachTo: null, ignoreMatches: true })
  await saveOne(i)
  finish()
}

async function submit(): Promise<void> {
  if (!ready.value.length) return
  busy.value = true
  for (let i = 0; i < rows.value.length; i += 1) {
    const r = rows.value[i]
    if (r && r.state === 'ready' && !r.problem && r.name.trim().length >= 2) await saveOne(i)
  }
  busy.value = false
  finish()
}

function finish(): void {
  emit('created', done.value)
  if (rows.value.every((r) => r.state === 'done')) dialog.value?.close()
}
</script>

<template>
  <dialog ref="dialog" class="upload-cvs" aria-labelledby="upload-cvs-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Recruitment</div>
      <h2 id="upload-cvs-title">Upload CVs — each one becomes a candidate.</h2>
      <p class="hint">Names are guessed from the file names; fix them here before saving. Every candidate starts at "New" with the CV on their record.</p>

      <div
        class="drop"
        :class="{ over: dragging }"
        @dragover.prevent="dragging = true"
        @dragleave="dragging = false"
        @drop.prevent="onDrop"
      >
        <input ref="fileInput" type="file" multiple :accept="FILE_ACCEPT" aria-label="CV files" hidden @change="onPick" />
        <button class="button secondary" type="button" @click="fileInput?.click()">Choose files</button>
        <span>or drop them here · PDF, Word, images · up to 10 MB each</span>
      </div>

      <div v-if="rows.length" class="rows">
        <div v-for="(r, i) in rows" :key="r.file.name + i" class="row" :class="r.state" :data-testid="`cv-row-${i}`">
          <div class="file" :title="r.file.name">{{ r.file.name }}</div>
          <input v-model="r.name" class="name" aria-label="Candidate name" maxlength="200" :disabled="r.state !== 'ready'" @input="setRow(i, { name: ($event.target as HTMLInputElement).value })" />
          <input v-model="r.email" class="email" aria-label="Email (optional)" placeholder="email (optional)" maxlength="320" :disabled="r.state !== 'ready'" @input="setRow(i, { email: ($event.target as HTMLInputElement).value })" />
          <span v-if="r.state === 'done'" class="badge green">Added</span>
          <span v-else-if="r.state === 'saving'" class="badge">Saving…</span>
          <span v-else-if="r.state === 'duplicate'" class="badge amber">Is this the same person?</span>
          <span v-else-if="r.problem" class="badge amber" :title="r.problem">{{ r.state === 'failed' ? 'Failed' : 'Skipped' }}</span>
          <button v-else class="linkish" type="button" aria-label="Remove" :disabled="busy" @click="removeRow(i)"><svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8" /></svg></button>
          <small v-if="r.problem" class="problem">{{ r.problem }}</small>
          <div v-if="r.state === 'duplicate' && r.matches" class="matches" :data-testid="`cv-matches-${i}`">
            <div v-for="m in r.matches" :key="m.id" class="match">
              <div class="match-text">
                <span>{{ matchSentence(m) }}</span>
                <span class="history">{{ matchHistoryLine(m) }}</span>
                <span v-if="alsoMatchedBy(i, m.id)" class="history">Also matched by row {{ alsoMatchedBy(i, m.id) }}</span>
              </div>
              <button
                v-if="m.attachable && !m.do_not_contact"
                class="button secondary small-btn"
                type="button"
                :data-testid="`cv-attach-${i}-${m.id}`"
                @click="attach(i, m.id)"
              >
                Attach to this job
              </button>
              <span v-else-if="m.do_not_contact" class="history">{{ m.full_name }} asked not to be contacted again.</span>
              <span v-else class="history">{{ NOT_ATTACHABLE }}</span>
            </div>
            <button class="button secondary small-btn" type="button" :data-testid="`cv-create-new-${i}`" @click="createNew(i)">
              Create a new candidate anyway
            </button>
          </div>
        </div>
      </div>

      <div class="actions">
        <span v-if="done" class="count">{{ done }} added</span>
        <button class="button secondary" type="button" @click="dialog?.close()">{{ done ? 'Close' : 'Cancel' }}</button>
        <button class="button" type="submit" :disabled="busy || !ready.length">
          {{ busy ? 'Saving…' : `Save ${ready.length || ''} candidate${ready.length === 1 ? '' : 's'}` }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.upload-cvs { border: 0; border-radius: 15px; padding: 0; width: min(720px, calc(100vw - 36px)); box-shadow: 0 25px 100px #122f3038; color: var(--ink); }
.upload-cvs::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 8px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin: 0 0 16px; }
.drop { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; padding: 18px; border: 1.5px dashed #c9d3c4; border-radius: 10px; font-size: 12px; color: var(--muted); }
.drop.over { border-color: var(--green); background: #f1f5ef; }
.rows { margin-top: 16px; max-height: min(50vh, 420px); overflow: auto; display: grid; gap: 8px; }
.row { display: grid; grid-template-columns: minmax(0, 1.2fr) minmax(0, 1fr) minmax(0, 1fr) auto; gap: 8px; align-items: center; font-size: 12px; }
.row .file { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); font-size: 11px; }
.row input { border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; min-width: 0; }
.row.done input { background: #f7f8f5; }
.row .problem { grid-column: 1 / -1; color: #946d24; font-size: 11px; }
.row .matches { grid-column: 1 / -1; display: grid; gap: 8px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: #fbfcfa; }
.match { display: flex; gap: 10px; align-items: center; justify-content: space-between; flex-wrap: wrap; }
.match-text { display: grid; gap: 2px; font-size: 12px; }
.history { color: var(--muted); font-size: 11px; }
.matches > .small-btn { justify-self: end; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.linkish { background: none; border: 0; color: var(--muted); font-size: 16px; padding: 0 6px; }
.actions { display: flex; gap: 9px; justify-content: flex-end; align-items: center; margin-top: 18px; }
.count { margin-right: auto; font-size: 12px; color: #3e744e; font-weight: 550; }
@media (max-width: 560px) { .row { grid-template-columns: 1fr; } }
</style>
