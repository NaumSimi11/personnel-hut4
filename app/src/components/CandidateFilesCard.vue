<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { FILE_ACCEPT, formatBytes, signedFileUrl, validateApplicationFile } from '@/lib/applicationFiles'
import {
  CANDIDATE_FILE_KINDS,
  listCandidateFiles,
  removeCandidateFile,
  uploadCandidateFile,
  type CandidateFileKind,
  type CandidateFileRow,
} from '@/lib/candidateFiles'

/**
 * The candidate's own documents (plan 052): the CV that follows the person
 * to every job, on the candidate rather than on one application. Private
 * bucket, signed links only; rows list what was attached, by whom and when.
 * `canEdit` is a hint — the candidate_files policies (can_edit_candidate)
 * decide.
 */

const props = withDefaults(defineProps<{ candidateId: string; canEdit: boolean; heading?: string }>(), {
  heading: 'Files',
})

const auth = useAuthStore()
const dialogs = useDialogStore()
const files = ref<CandidateFileRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const busy = ref(false)
const kind = ref<CandidateFileKind>('cv')
const pending = ref<File | null>(null)
const fileInput = ref<HTMLInputElement | null>(null)

function kindLabel(key: CandidateFileKind): string {
  return CANDIDATE_FILE_KINDS.find((k) => k.key === key)?.label ?? key
}

async function load(): Promise<void> {
  loading.value = true
  try {
    files.value = await listCandidateFiles(props.candidateId)
  } catch (e) {
    error.value = 'Could not load files. Check your access and connection.'
    console.error('Candidate files load failed:', e instanceof Error ? e.message : e)
  } finally {
    loading.value = false
  }
}

function onPick(event: Event): void {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0] ?? null
  error.value = null
  if (!file) {
    pending.value = null
    return
  }
  const problem = validateApplicationFile(file)
  if (problem) {
    error.value = problem
    input.value = ''
    pending.value = null
    return
  }
  pending.value = file
}

async function upload(): Promise<void> {
  if (!pending.value) {
    error.value = 'Choose a file first.'
    return
  }
  error.value = null
  busy.value = true
  try {
    await uploadCandidateFile({
      candidateId: props.candidateId,
      file: pending.value,
      kind: kind.value,
      uploadedBy: auth.personId,
    })
    pending.value = null
    if (fileInput.value) fileInput.value.value = ''
    await load()
  } catch (e) {
    error.value = e instanceof Error ? friendly(e.message) : 'Upload failed.'
  } finally {
    busy.value = false
  }
}

async function download(row: CandidateFileRow): Promise<void> {
  error.value = null
  // Open the tab synchronously inside the click, then point it at the signed
  // URL once it exists — a window opened after an await is blocked by Safari.
  const tab = window.open('', '_blank')
  try {
    const url = await signedFileUrl(row.storage_path)
    if (tab) {
      tab.opener = null
      tab.location.href = url
    } else {
      window.location.assign(url)
    }
  } catch (e) {
    tab?.close()
    error.value = e instanceof Error ? friendly(e.message) : 'Could not open the file.'
  }
}

async function remove(row: CandidateFileRow): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Remove ${row.original_name}?`,
    hint: `The ${kindLabel(row.kind).toLowerCase()} is deleted from the candidate's record. This cannot be undone.`,
    confirmLabel: 'Remove file',
    danger: true,
  })
  if (!ok) return
  error.value = null
  busy.value = true
  try {
    await removeCandidateFile(row.id, row.storage_path)
    await load()
  } catch (e) {
    error.value = e instanceof Error ? friendly(e.message) : 'Could not remove the file.'
  } finally {
    busy.value = false
  }
}

function friendly(message: string): string {
  // Only a policy denial is a permission problem; a CHECK violation keeps its own sentence.
  if (/row-level security/.test(message)) {
    return 'Changing this candidate\'s files needs the "Work the talent pool" capability, or "Record interview feedback" where they applied.'
  }
  return message
}

onMounted(load)
</script>

<template>
  <div class="card" data-testid="candidate-files">
    <div class="card-head">
      <div>
        <h2>{{ heading }}</h2>
        <p>Private to people who may see this candidate. Links expire in two minutes.</p>
      </div>
    </div>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
    <div v-if="loading" class="empty">Loading files…</div>
    <div v-else-if="!files.length" class="empty">No files yet. The CV goes here — it follows the person to every job.</div>
    <div v-else>
      <div v-for="f in files" :key="f.id" class="file-row" :data-testid="`candidate-file-${f.id}`">
        <div class="row-text">
          <strong>{{ f.original_name }}</strong>
          <small>
            {{ kindLabel(f.kind) }} · {{ formatBytes(f.size_bytes) }} ·
            {{ new Date(f.created_at).toLocaleDateString() }}
            <template v-if="f.uploader"> · {{ f.uploader.full_name }}</template>
          </small>
        </div>
        <div class="row-actions">
          <button class="button secondary small-btn" type="button" @click="download(f)">Download</button>
          <button v-if="canEdit" class="button secondary small-btn" type="button" :disabled="busy" @click="remove(f)">
            Remove
          </button>
        </div>
      </div>
    </div>
    <form v-if="canEdit" class="upload" @submit.prevent="upload">
      <select id="candidate-file-kind" v-model="kind" aria-label="File kind">
        <option v-for="k in CANDIDATE_FILE_KINDS" :key="k.key" :value="k.key">{{ k.label }}</option>
      </select>
      <input
        id="candidate-file-input"
        ref="fileInput"
        type="file"
        :accept="FILE_ACCEPT"
        aria-label="File"
        @change="onPick"
      />
      <button class="button small-btn" type="submit" :disabled="busy">{{ busy ? 'Uploading…' : 'Upload' }}</button>
    </form>
  </div>
</template>

<style scoped>
.file-row {
  display: flex;
  align-items: center;
  gap: 13px;
  padding: 13px 24px;
  border-top: 1px solid #edf0eb;
  flex-wrap: wrap;
}
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.row-actions { display: flex; gap: 7px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.upload {
  display: flex;
  gap: 8px;
  align-items: center;
  flex-wrap: wrap;
  padding: 14px 24px;
  border-top: 1px solid var(--line);
  background: #fafbf9;
}
.upload select, .upload input[type='file'] {
  border: 1px solid #dce3d7;
  padding: 7px 10px;
  background: #fff;
  color: var(--ink);
  font-size: 11px;
}
.upload input[type='file'] { flex: 1; min-width: 200px; }
</style>
