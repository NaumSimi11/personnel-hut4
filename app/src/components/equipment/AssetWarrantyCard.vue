<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useDialogStore } from '@/stores/dialogs'
import { localToday } from '@/lib/inventoryPrint'
import { ACCEPTED_TYPES, assetFilePath, fileProblem, shrinkTo, warrantyLine } from '@/lib/warranty'

/**
 * Warranty on one item (24 Nov, 0130): purchase date, warranty end, and the
 * scanned warranty or invoice. Photos are shrunk in the browser before they
 * go up; every file is capped at 2 MB (the storage plan is small).
 */
const props = defineProps<{
  assetId: string
  companyId: string | null
  mayWork: boolean
  purchaseDate: string | null
  warrantyUntil: string | null
}>()
const emit = defineEmits<{ changed: [] }>()

type FileRow = { id: string; storage_path: string; original_name: string; mime_type: string; size_bytes: number; created_at: string }

const dialogs = useDialogStore()
const files = ref<FileRow[]>([])
const editing = ref(false)
const form = ref({ purchaseDate: props.purchaseDate ?? '', warrantyUntil: props.warrantyUntil ?? '' })
const busy = ref(false)
const error = ref<string | null>(null)
const picker = ref<HTMLInputElement | null>(null)

const line = computed(() => warrantyLine(props.warrantyUntil, localToday()))
const accept = ACCEPTED_TYPES.join(',')

async function load(): Promise<void> {
  const { data, error: err } = await supabase
    .from('asset_files')
    .select('id, storage_path, original_name, mime_type, size_bytes, created_at')
    .eq('asset_id', props.assetId)
    .order('created_at', { ascending: false })
  if (err) {
    error.value = 'Could not load the warranty files.'
    console.error('Asset files load failed:', err.message)
    return
  }
  files.value = data ?? []
}

async function saveDates(): Promise<void> {
  error.value = null
  if (form.value.purchaseDate && form.value.warrantyUntil && form.value.warrantyUntil < form.value.purchaseDate) {
    error.value = 'The warranty cannot end before the purchase date.'
    return
  }
  busy.value = true
  const { error: err } = await supabase
    .from('assets')
    .update({ purchase_date: form.value.purchaseDate || null, warranty_until: form.value.warrantyUntil || null })
    .eq('id', props.assetId)
  busy.value = false
  if (err) {
    error.value = 'Could not save the dates.'
    console.error('Warranty dates save failed:', err.message)
    return
  }
  editing.value = false
  emit('changed')
}

/** A photo redrawn at most 1,800 px on its long side, as a JPEG; a PDF as it is. */
async function prepare(file: File): Promise<Blob> {
  if (!file.type.startsWith('image/')) return file
  const bitmap = await createImageBitmap(file)
  const size = shrinkTo(bitmap.width, bitmap.height)
  const canvas = document.createElement('canvas')
  canvas.width = size.width
  canvas.height = size.height
  canvas.getContext('2d')?.drawImage(bitmap, 0, 0, size.width, size.height)
  return await new Promise<Blob>((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not read the image.'))), 'image/jpeg', 0.82),
  )
}

async function upload(event: Event): Promise<void> {
  const file = (event.target as HTMLInputElement).files?.[0]
  if (picker.value) picker.value.value = ''
  if (!file || !props.companyId) return
  error.value = null
  busy.value = true
  try {
    const blob = await prepare(file)
    const type = file.type.startsWith('image/') ? 'image/jpeg' : file.type
    const problem = fileProblem({ type, size: blob.size })
    if (problem) throw new Error(problem)
    const name = type === 'image/jpeg' && !/\.jpe?g$/i.test(file.name) ? `${file.name.replace(/\.[^.]+$/, '')}.jpg` : file.name
    const path = assetFilePath(props.companyId, props.assetId, name, crypto.randomUUID())
    const up = await supabase.storage.from('asset-files').upload(path, blob, { contentType: type, upsert: false })
    if (up.error) throw new Error(up.error.message)
    const row = await supabase.from('asset_files').insert({
      asset_id: props.assetId,
      company_id: props.companyId,
      storage_path: path,
      original_name: name.slice(0, 200),
      mime_type: type,
      size_bytes: blob.size,
    })
    if (row.error) {
      await supabase.storage.from('asset-files').remove([path])
      throw new Error(row.error.message)
    }
    await load()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not upload the file.'
    console.error('Warranty upload failed:', error.value)
  } finally {
    busy.value = false
  }
}

async function openFile(f: FileRow): Promise<void> {
  const { data, error: err } = await supabase.storage.from('asset-files').createSignedUrl(f.storage_path, 120)
  if (err || !data) {
    error.value = 'Could not open the file.'
    console.error('Signed URL failed:', err?.message)
    return
  }
  window.open(data.signedUrl, '_blank', 'noopener')
}

async function remove(f: FileRow): Promise<void> {
  const ok = await dialogs.confirmAction({ title: `Delete ${f.original_name}?`, confirmLabel: 'Delete', danger: true })
  if (!ok) return
  const { error: err } = await supabase.from('asset_files').delete().eq('id', f.id)
  if (err) {
    error.value = 'Could not delete the file.'
    console.error('Asset file delete failed:', err.message)
    return
  }
  const gone = await supabase.storage.from('asset-files').remove([f.storage_path])
  if (gone.error) console.error('Storage remove failed:', gone.error.message)
  await load()
}

function kb(bytes: number): string {
  return bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`
}

onMounted(() => {
  void load()
})
</script>

<template>
  <section class="card" data-testid="warranty-card">
    <div class="card-head">
      <div>
        <h2>Warranty</h2>
        <p :class="{ soon: line.soon, ended: line.ended }">{{ line.text }}{{ purchaseDate ? ` · bought ${purchaseDate}` : '' }}</p>
      </div>
      <div v-if="mayWork" class="actions">
        <button type="button" class="button secondary small-btn" @click="editing = !editing">{{ editing ? 'Cancel' : 'Edit dates' }}</button>
        <button v-if="companyId" type="button" class="button small-btn" :disabled="busy" data-testid="warranty-upload" @click="picker?.click()">
          {{ busy ? 'Uploading…' : 'Upload scan' }}
        </button>
        <input ref="picker" type="file" :accept="accept" hidden @change="upload" />
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <div v-if="editing" class="dates">
      <label>Bought on <input v-model="form.purchaseDate" type="date" /></label>
      <label>Warranty until <input v-model="form.warrantyUntil" type="date" /></label>
      <button type="button" class="button small-btn" :disabled="busy" @click="saveDates">Save</button>
    </div>
    <ul class="files">
      <li v-for="f in files" :key="f.id">
        <button type="button" class="link" @click="openFile(f)">{{ f.original_name }}</button>
        <span class="muted">{{ kb(f.size_bytes) }} · {{ f.created_at.slice(0, 10) }}</span>
        <button v-if="mayWork" type="button" class="link danger-text" @click="remove(f)">Delete</button>
      </li>
      <li v-if="!files.length" class="muted">No scans yet. Images and PDFs up to 2 MB; photos are shrunk on upload.</li>
    </ul>
  </section>
</template>

<style scoped>
.in-card { margin: 12px 24px 0; }
.actions { display: flex; gap: 8px; }
.dates { display: flex; gap: 12px; align-items: flex-end; flex-wrap: wrap; padding: 12px 24px; border-top: 1px solid #edf0eb; font-size: 12px; }
.dates label { display: flex; flex-direction: column; gap: 4px; }
.dates input { border: 1px solid #dce3d7; padding: 7px 10px; font-size: 12px; }
.files { list-style: none; margin: 0; padding: 0; }
.files li { display: flex; gap: 12px; align-items: center; padding: 10px 24px; border-top: 1px solid #edf0eb; font-size: 12px; }
.link { background: none; border: 0; padding: 0; color: var(--green, #2f6b4f); cursor: pointer; text-decoration: underline; font-size: 12px; }
.muted { color: var(--muted); }
.soon { color: #8a5a00; }
.ended { color: #8a3b12; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
