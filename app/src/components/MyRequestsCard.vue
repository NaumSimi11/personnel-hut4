<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { DOCUMENT_ACCEPT, uploadDocument, validateDocumentFile } from '@/lib/documents'
import { OPEN_REQUEST, requestStatusLabel, type DocumentRequestRow } from '@/lib/policies'

/**
 * The person's side of document requests (plan 028): what HR asked for,
 * with an upload for open requests. The upload goes through the
 * self-service window (a documents row of the requested category, forced
 * person_and_hr) and submit_requested_document links it to the request.
 */

const auth = useAuthStore()
const loading = ref(true)
const busyId = ref<string | null>(null)
const error = ref<string | null>(null)
const requests = ref<(DocumentRequestRow & { company: { name: string } | null })[]>([])
const categories = ref<Record<string, string>>({})
const files = ref<Record<string, File | null>>({})

const categoryLabel = (key: string) => categories.value[key] ?? key

async function load(): Promise<void> {
  if (!auth.personId) {
    loading.value = false
    return
  }
  loading.value = true
  error.value = null
  const [reqRes, catRes] = await Promise.all([
    supabase
      .from('document_requests')
      .select('*, company:companies(name)')
      .eq('person_id', auth.personId)
      .order('created_at', { ascending: false }),
    supabase.from('document_categories').select('key, label'),
  ])
  if (reqRes.error || catRes.error) {
    error.value = 'Could not load your document requests.'
    console.error('My requests load failed:', reqRes.error?.message ?? catRes.error?.message)
    loading.value = false
    return
  }
  requests.value = (reqRes.data ?? []) as typeof requests.value
  categories.value = Object.fromEntries((catRes.data ?? []).map((c) => [c.key, c.label]))
  loading.value = false
}

function pick(requestId: string, event: Event): void {
  const input = event.target as HTMLInputElement
  files.value = { ...files.value, [requestId]: input.files?.[0] ?? null }
}

async function submit(request: DocumentRequestRow): Promise<void> {
  const file = files.value[request.id]
  if (!file) {
    error.value = 'Choose the file to upload.'
    return
  }
  const problem = validateDocumentFile(file)
  if (problem) {
    error.value = problem
    return
  }
  busyId.value = request.id
  error.value = null
  try {
    const doc = await uploadDocument({
      companyId: request.company_id,
      personId: request.person_id,
      file,
      form: { title: categoryLabel(request.category_key), categoryKey: request.category_key, visibility: 'person_and_hr', note: '' },
    })
    const { error: err } = await supabase.rpc('submit_requested_document', { p_request_id: request.id, p_document_id: doc.id })
    if (err) throw new Error(err.message)
    files.value = { ...files.value, [request.id]: null }
    await load()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Upload failed.'
    console.error('Requested document submission failed:', error.value)
  } finally {
    busyId.value = null
  }
}

onMounted(load)
</script>

<template>
  <div v-if="requests.length || loading" class="card">
    <div class="card-head">
      <div>
        <h2>Requested from you</h2>
        <p>Documents HR has asked for. Only you and HR can see what you upload here.</p>
      </div>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="error" class="error" role="alert">{{ error }}</div>
      <div v-for="r in requests" :key="r.id" class="request-row" :class="r.status">
        <div class="row-text">
          <strong>{{ categoryLabel(r.category_key) }} · {{ r.company?.name ?? '' }}</strong>
          <small>
            {{ requestStatusLabel(r.status) }}
            <template v-if="r.due_date"> · due {{ r.due_date }}</template>
            <template v-if="r.note"> · {{ r.note }}</template>
          </small>
        </div>
        <form v-if="OPEN_REQUEST.has(r.status)" class="upload" @submit.prevent="submit(r)">
          <input type="file" :accept="DOCUMENT_ACCEPT" @change="pick(r.id, $event)" />
          <button class="button small-btn" type="submit" :disabled="busyId === r.id">
            {{ busyId === r.id ? 'Uploading…' : 'Submit' }}
          </button>
        </form>
      </div>
    </template>
  </div>
</template>

<style scoped>
.request-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.request-row.accepted, .request-row.cancelled { opacity: 0.65; }
.request-row.needs_correction { background: #fbf7ea; }
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.upload { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.upload input { font-size: 11px; max-width: 220px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
</style>
