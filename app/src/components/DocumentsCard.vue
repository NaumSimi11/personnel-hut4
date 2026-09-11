<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { formatBytes } from '@/lib/applicationFiles'
import {
  DOCUMENT_ACCEPT,
  archiveDocument,
  documentInput,
  signedDocumentUrl,
  uploadDocument,
  validateDocumentFile,
  visibilityLabel,
  visibilityOptions,
  type DocumentRow,
  type Visibility,
} from '@/lib/documents'

/**
 * Documents for one person (across their employments) or one company
 * (plan 026). The card only decides whether to attempt the load; RLS on
 * `documents` (0006) is the real gate: HR with documents.view, the person
 * for anything not hr_only, everyone in the company for company_public.
 * Uploads, new versions and archiving need documents.upload in the company.
 */

type Company = { id: string; name: string }

const props = withDefaults(
  defineProps<{
    personId?: string | null
    companies: Company[]
    title?: string
  }>(),
  { personId: null, title: 'Documents' },
)

const auth = useAuthStore()
const scope = computed(() => (props.personId ? 'person' : 'company'))
const visible = computed(
  () =>
    auth.isAdmin ||
    (props.personId !== null && auth.personId === props.personId) ||
    props.companies.some((c) => auth.can(c.id, 'documents.view') || auth.can(c.id, 'documents.upload')),
)
const uploadCompanies = computed(() => props.companies.filter((c) => auth.can(c.id, 'documents.upload')))

const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const documents = ref<DocumentRow[]>([])
const categories = ref<{ key: string; label: string; person_scoped: boolean }[]>([])
const names = ref<Record<string, string>>({})
const showArchived = ref(false)

const adding = ref(false)
const replacing = ref<DocumentRow | null>(null)
const form = ref<{ companyId: string; title: string; categoryKey: string; visibility: Visibility; note: string }>({
  companyId: '',
  title: '',
  categoryKey: '',
  visibility: 'person_and_hr',
  note: '',
})
const fileInput = ref<HTMLInputElement | null>(null)

const scopedCategories = computed(() => categories.value.filter((c) => c.person_scoped === (scope.value === 'person')))
const visibilities = computed(() => visibilityOptions(scope.value))
const shown = computed(() =>
  documents.value
    .filter((d) => showArchived.value || d.archived_at === null)
    .sort((a, b) => Number(a.archived_at !== null) - Number(b.archived_at !== null) || b.created_at.localeCompare(a.created_at)),
)
const archivedCount = computed(() => documents.value.filter((d) => d.archived_at !== null).length)

const categoryLabel = (key: string) => categories.value.find((c) => c.key === key)?.label ?? key
const companyName = (id: string) => props.companies.find((c) => c.id === id)?.name ?? ''
const personName = (id: string | null) => (id ? (names.value[id] ?? 'someone') : '—')
const canManage = (doc: DocumentRow) => auth.can(doc.company_id, 'documents.upload')

async function load(): Promise<void> {
  if (!visible.value || !props.companies.length) {
    loading.value = false
    return
  }
  loading.value = true
  error.value = null
  let query = supabase
    .from('documents')
    .select('*')
    .in('company_id', props.companies.map((c) => c.id))
  query = props.personId ? query.eq('person_id', props.personId) : query.is('person_id', null)
  const [docRes, catRes] = await Promise.all([
    query.order('created_at', { ascending: false }),
    supabase.from('document_categories').select('key, label, person_scoped').is('archived_at', null).order('sort_order'),
  ])
  if (docRes.error || catRes.error) {
    error.value = 'Could not load documents.'
    console.error('Documents load failed:', docRes.error?.message ?? catRes.error?.message)
    loading.value = false
    return
  }
  documents.value = (docRes.data ?? []) as DocumentRow[]
  categories.value = catRes.data ?? []
  const ids = [...new Set(documents.value.map((d) => d.uploaded_by).filter((id): id is string => !!id))]
  if (ids.length) {
    const { data } = await supabase.from('people').select('id, full_name').in('id', ids)
    names.value = Object.fromEntries((data ?? []).map((p) => [p.id, p.full_name]))
  }
  loading.value = false
}

function startAdd(): void {
  replacing.value = null
  form.value = {
    companyId: uploadCompanies.value[0]?.id ?? '',
    title: '',
    categoryKey: scopedCategories.value[0]?.key ?? '',
    visibility: scope.value === 'person' ? 'person_and_hr' : 'company_public',
    note: '',
  }
  error.value = null
  notice.value = null
  adding.value = true
}

function startVersion(doc: DocumentRow): void {
  replacing.value = doc
  form.value = {
    companyId: doc.company_id,
    title: doc.title,
    categoryKey: doc.category_key,
    visibility: doc.visibility as Visibility,
    note: '',
  }
  error.value = null
  notice.value = null
  adding.value = true
}

function cancel(): void {
  adding.value = false
  replacing.value = null
}

async function submit(): Promise<void> {
  const file = fileInput.value?.files?.[0]
  if (!file) {
    error.value = 'Choose the file to upload.'
    return
  }
  const fileProblem = validateDocumentFile(file)
  if (fileProblem) {
    error.value = fileProblem
    return
  }
  const parsed = documentInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  if (!form.value.companyId) {
    error.value = 'Choose the company this document belongs to.'
    return
  }
  busy.value = true
  error.value = null
  try {
    await uploadDocument({
      companyId: form.value.companyId,
      personId: props.personId,
      file,
      form: parsed.data,
      supersedesId: replacing.value?.id ?? null,
    })
    notice.value = replacing.value ? `Version ${replacing.value.version + 1} uploaded; the previous version is archived.` : 'Document uploaded.'
    cancel()
    await load()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Upload failed.'
    console.error('Document upload failed:', error.value)
  } finally {
    busy.value = false
  }
}

async function open(doc: DocumentRow): Promise<void> {
  error.value = null
  // Open the tab first so the browser treats it as a user gesture, then point it at the signed link.
  const tab = window.open('', '_blank')
  try {
    const url = await signedDocumentUrl(doc.storage_path)
    if (tab) tab.location.href = url
    else window.location.href = url
  } catch (e) {
    tab?.close()
    error.value = e instanceof Error ? e.message : 'Could not open the document.'
    console.error('Document open failed:', error.value)
  }
}

async function archive(doc: DocumentRow): Promise<void> {
  if (!window.confirm(`Archive "${doc.title}"? It stays on record but leaves the live list.`)) return
  busy.value = true
  error.value = null
  try {
    await archiveDocument(doc.id)
    notice.value = 'Document archived.'
    await load()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Archive failed.'
    console.error('Document archive failed:', error.value)
  } finally {
    busy.value = false
  }
}

onMounted(load)
// Keyed on a string so only a real change in scope reloads (and never drops an open form).
watch(
  () => `${props.personId ?? ''}|${props.companies.map((c) => c.id).join(',')}`,
  () => load(),
)
</script>

<template>
  <div v-if="visible" class="card">
    <div class="card-head">
      <div>
        <h2>{{ title }}</h2>
        <p>Versions are kept; nothing is overwritten. Files open through short-lived links.</p>
      </div>
      <button v-if="uploadCompanies.length && !adding" class="button small-btn" type="button" @click="startAdd">
        Add document
      </button>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="notice" class="notice" role="status">{{ notice }}</div>
      <div v-if="error" class="error" role="alert">{{ error }}</div>

      <form v-if="adding" class="doc-form" novalidate @submit.prevent="submit">
        <div class="form-title">{{ replacing ? `New version of “${replacing.title}”` : 'New document' }}</div>
        <label v-if="!replacing && uploadCompanies.length > 1">
          <span>Company</span>
          <select id="doc-company" v-model="form.companyId">
            <option v-for="c in uploadCompanies" :key="c.id" :value="c.id">{{ c.name }}</option>
          </select>
        </label>
        <label>
          <span>Title</span>
          <input id="doc-title" v-model="form.title" maxlength="160" :disabled="!!replacing" />
        </label>
        <label>
          <span>Category</span>
          <select id="doc-category" v-model="form.categoryKey" :disabled="!!replacing">
            <option v-for="c in scopedCategories" :key="c.key" :value="c.key">{{ c.label }}</option>
          </select>
        </label>
        <label>
          <span>Visibility</span>
          <select id="doc-visibility" v-model="form.visibility">
            <option v-for="v in visibilities" :key="v.key" :value="v.key">{{ v.label }}</option>
          </select>
        </label>
        <label>
          <span>File</span>
          <input id="doc-file" ref="fileInput" type="file" :accept="DOCUMENT_ACCEPT" />
        </label>
        <label class="wide">
          <span>Note</span>
          <input id="doc-note" v-model="form.note" placeholder="Optional" />
        </label>
        <div class="form-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="cancel">Cancel</button>
          <button type="submit" class="button small-btn" :disabled="busy">{{ busy ? 'Uploading…' : 'Upload' }}</button>
        </div>
      </form>

      <div v-if="!shown.length" class="empty">No documents yet.</div>
      <div v-for="doc in shown" :key="doc.id" class="doc-row" :class="{ archived: doc.archived_at !== null }">
        <div class="row-text">
          <strong>{{ doc.title }} <span class="version">v{{ doc.version }}</span></strong>
          <small>
            {{ categoryLabel(doc.category_key) }} · {{ visibilityLabel(doc.visibility) }}
            <template v-if="companies.length > 1"> · {{ companyName(doc.company_id) }}</template>
            · {{ doc.created_at.slice(0, 10) }} by {{ personName(doc.uploaded_by) }}
            <template v-if="doc.size_bytes"> · {{ formatBytes(doc.size_bytes) }}</template>
            <template v-if="doc.archived_at"> · archived {{ doc.archived_at.slice(0, 10) }}</template>
            <template v-if="doc.note"> · {{ doc.note }}</template>
          </small>
        </div>
        <div class="actions">
          <button class="button secondary small-btn" type="button" @click="open(doc)">Open</button>
          <template v-if="canManage(doc) && doc.archived_at === null">
            <button class="button secondary small-btn" type="button" :disabled="busy" @click="startVersion(doc)">New version</button>
            <button class="button secondary small-btn" type="button" :disabled="busy" @click="archive(doc)">Archive</button>
          </template>
        </div>
      </div>
      <div v-if="archivedCount" class="toggle">
        <button class="link" type="button" @click="showArchived = !showArchived">
          {{ showArchived ? 'Hide archived' : `Show archived (${archivedCount})` }}
        </button>
      </div>
    </template>
  </div>
</template>

<style scoped>
.doc-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.doc-row.archived { opacity: 0.6; }
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.version { font-size: 10px; font-weight: 600; color: var(--muted); margin-left: 4px; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.doc-form { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 14px; padding: 16px 24px; background: #fafbf8; border-top: 1px solid var(--line); }
.form-title { grid-column: 1 / -1; font-size: 12px; font-weight: 600; }
.doc-form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.doc-form label.wide, .doc-form .form-actions { grid-column: 1 / -1; }
.doc-form input, .doc-form select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
.form-actions { display: flex; justify-content: flex-end; gap: 8px; }
.toggle { padding: 10px 24px 14px; border-top: 1px solid #edf0eb; }
.link { border: 0; background: none; color: var(--green); font-size: 11px; padding: 0; cursor: pointer; text-decoration: underline; }
.notice { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
@media (max-width: 560px) { .doc-form { grid-template-columns: 1fr; } }
</style>
