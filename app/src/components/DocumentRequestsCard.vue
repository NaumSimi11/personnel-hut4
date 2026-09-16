<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { signedDocumentUrl } from '@/lib/documents'
import {
  OPEN_REQUEST,
  friendlyRequestError,
  requestInput,
  requestStatusLabel,
  type DocumentRequestRow,
} from '@/lib/policies'

/**
 * HR's side of document requests for one person (plan 028): ask for a
 * document, watch its state, accept or send back what was submitted.
 * Reading needs documents.view or documents.request in the company; writes
 * go through review_document_request (documents.request).
 */

type Company = { id: string; name: string }
const props = defineProps<{ personId: string; companies: Company[] }>()

const auth = useAuthStore()
const dialogs = useDialogStore()
const canRequestIn = computed(() => props.companies.filter((c) => auth.can(c.id, 'documents.request')))
const visible = computed(
  () =>
    auth.isAdmin ||
    props.companies.some((c) => auth.can(c.id, 'documents.view') || auth.can(c.id, 'documents.request')),
)

const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const requests = ref<DocumentRequestRow[]>([])
const categories = ref<{ key: string; label: string }[]>([])
const documents = ref<Record<string, { storage_path: string; title: string; version: number }>>({})
const adding = ref(false)
const form = ref({ companyId: '', categoryKey: '', dueDate: '', note: '' })

const categoryLabel = (key: string) => categories.value.find((c) => c.key === key)?.label ?? key
const companyName = (id: string) => props.companies.find((c) => c.id === id)?.name ?? ''

async function load(): Promise<void> {
  if (!visible.value || !props.companies.length) {
    loading.value = false
    return
  }
  loading.value = true
  error.value = null
  const [reqRes, catRes] = await Promise.all([
    supabase
      .from('document_requests')
      .select('*')
      .eq('person_id', props.personId)
      .in('company_id', props.companies.map((c) => c.id))
      .order('created_at', { ascending: false }),
    supabase.from('document_categories').select('key, label').eq('person_scoped', true).is('archived_at', null).order('sort_order'),
  ])
  if (reqRes.error || catRes.error) {
    error.value = 'Could not load document requests.'
    console.error('Document requests load failed:', reqRes.error?.message ?? catRes.error?.message)
    loading.value = false
    return
  }
  requests.value = (reqRes.data ?? []) as DocumentRequestRow[]
  categories.value = catRes.data ?? []
  const docIds = requests.value.map((r) => r.fulfilled_document_id).filter((id): id is string => !!id)
  if (docIds.length) {
    const { data } = await supabase.from('documents').select('id, storage_path, title, version').in('id', docIds)
    documents.value = Object.fromEntries((data ?? []).map((d) => [d.id, d]))
  }
  loading.value = false
}

function startRequest(): void {
  form.value = { companyId: canRequestIn.value[0]?.id ?? '', categoryKey: categories.value[0]?.key ?? '', dueDate: '', note: '' }
  error.value = null
  notice.value = null
  adding.value = true
}

async function submitRequest(): Promise<void> {
  const parsed = requestInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('document_requests')
    .insert({
      company_id: form.value.companyId,
      person_id: props.personId,
      category_key: parsed.data.categoryKey,
      due_date: parsed.data.dueDate || null,
      note: parsed.data.note || null,
    })
    .select('id')
    .maybeSingle()
  busy.value = false
  if (err || !data) {
    error.value = friendlyRequestError(err?.message ?? 'row-level security')
    console.error('Document request failed:', err?.message ?? 'no row returned')
    return
  }
  adding.value = false
  notice.value = 'Request sent — the person sees it in their workspace.'
  await load()
}

async function review(request: DocumentRequestRow, decision: 'accepted' | 'needs_correction' | 'cancelled'): Promise<void> {
  let note: string | null = null
  if (decision === 'needs_correction') {
    const answer = await dialogs.askReason({
      title: 'What needs to change?',
      hint: `The ${categoryLabel(request.category_key).toLowerCase()} goes back to the person with this note.`,
      label: 'Note',
      required: false,
      confirmLabel: 'Send back',
    })
    if (!answer) return
    note = answer.reason
  }
  if (decision === 'cancelled') {
    const ok = await dialogs.confirmAction({
      title: `Cancel the request for ${categoryLabel(request.category_key).toLowerCase()}?`,
      hint: 'It leaves the person\'s workspace; nothing already submitted is deleted.',
      confirmLabel: 'Cancel request',
      cancelLabel: 'Keep it',
      danger: true,
    })
    if (!ok) return
  }
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err } = await supabase.rpc('review_document_request', {
    p_request_id: request.id,
    p_decision: decision,
    p_note: note || undefined,
  })
  busy.value = false
  if (err) {
    error.value = friendlyRequestError(err.message)
    console.error('Document request review failed:', err.message)
    return
  }
  await load()
}

async function openDocument(documentId: string): Promise<void> {
  const doc = documents.value[documentId]
  if (!doc) return
  const tab = window.open('', '_blank')
  try {
    const url = await signedDocumentUrl(doc.storage_path)
    if (tab) tab.location.href = url
  } catch (e) {
    tab?.close()
    error.value = e instanceof Error ? e.message : 'Could not open the document.'
  }
}

onMounted(load)
watch(
  () => `${props.personId}|${props.companies.map((c) => c.id).join(',')}`,
  () => load(),
)
</script>

<template>
  <div v-if="visible" class="card">
    <div class="card-head">
      <div>
        <h2>Document requests</h2>
        <p>Ask for a document; the person uploads it from their workspace and you accept it.</p>
      </div>
      <button v-if="canRequestIn.length && !adding" class="button small-btn" type="button" @click="startRequest">
        Request a document
      </button>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="notice" class="notice" role="status">{{ notice }}</div>
      <div v-if="error" class="error" role="alert">{{ error }}</div>

      <form v-if="adding" class="req-form" novalidate @submit.prevent="submitRequest">
        <label v-if="canRequestIn.length > 1">
          <span>Company</span>
          <select id="req-company" v-model="form.companyId">
            <option v-for="c in canRequestIn" :key="c.id" :value="c.id">{{ c.name }}</option>
          </select>
        </label>
        <label>
          <span>Document</span>
          <select id="req-category" v-model="form.categoryKey">
            <option v-for="c in categories" :key="c.key" :value="c.key">{{ c.label }}</option>
          </select>
        </label>
        <label>
          <span>Due by</span>
          <input id="req-due" v-model="form.dueDate" type="date" />
        </label>
        <label class="wide">
          <span>Note to the person</span>
          <input id="req-note" v-model="form.note" placeholder="What exactly, and why (optional)" />
        </label>
        <div class="form-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="adding = false">Cancel</button>
          <button type="submit" class="button small-btn" :disabled="busy">Send request</button>
        </div>
      </form>

      <div v-if="!requests.length" class="empty">Nothing requested.</div>
      <div v-for="r in requests" :key="r.id" class="request-row" :class="r.status">
        <div class="row-text">
          <strong>{{ categoryLabel(r.category_key) }}</strong>
          <small>
            {{ requestStatusLabel(r.status) }}
            <template v-if="r.due_date"> · due {{ r.due_date }}</template>
            <template v-if="companies.length > 1"> · {{ companyName(r.company_id) }}</template>
            <template v-if="r.note"> · {{ r.note }}</template>
          </small>
        </div>
        <div class="actions">
          <button
            v-if="r.fulfilled_document_id && documents[r.fulfilled_document_id]"
            class="button secondary small-btn"
            type="button"
            @click="openDocument(r.fulfilled_document_id)"
          >
            Open document
          </button>
          <template v-if="auth.can(r.company_id, 'documents.request')">
            <template v-if="r.status === 'submitted'">
              <button class="button small-btn" type="button" :disabled="busy" @click="review(r, 'accepted')">Accept</button>
              <button class="button secondary small-btn" type="button" :disabled="busy" @click="review(r, 'needs_correction')">Send back</button>
            </template>
            <button
              v-if="OPEN_REQUEST.has(r.status) || r.status === 'submitted'"
              class="button secondary small-btn"
              type="button"
              :disabled="busy"
              @click="review(r, 'cancelled')"
            >
              Cancel
            </button>
          </template>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.request-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.request-row.accepted, .request-row.cancelled { opacity: 0.65; }
.request-row.submitted { background: #fbf7ea; }
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.req-form { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 14px; padding: 16px 24px; background: #fafbf8; border-top: 1px solid var(--line); }
.req-form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.req-form label.wide, .req-form .form-actions { grid-column: 1 / -1; }
.req-form input, .req-form select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
.form-actions { display: flex; justify-content: flex-end; gap: 8px; }
.notice { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
@media (max-width: 560px) { .req-form { grid-template-columns: 1fr; } }
</style>
