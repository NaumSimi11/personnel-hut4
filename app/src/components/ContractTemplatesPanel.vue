<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import {
  TEMPLATE_FIELDS,
  canIssue,
  labelFor,
  placeholdersIn,
  renderTemplate,
} from '@shared/contractTemplate'

/**
 * The contract templates a company issues from.
 *
 * A template is prose with {{placeholders}}, so the editor's job is to make the
 * placeholders discoverable — nobody can be expected to guess that the field is
 * called company_legal_name — and to show what the text becomes for a real
 * person before anybody signs it. The preview uses whoever is picked rather
 * than invented data, because a template that renders beautifully against
 * "John Doe" and leaves a hole for the actual person is the failure this is
 * meant to prevent.
 *
 * A published template is never edited. Publishing again makes a new version
 * and archives the old, so a contract issued last month is still explicable.
 */
const props = defineProps<{ companyId: string | null }>()

type Template = {
  id: string
  company_id: string | null
  category_key: string
  title: string
  body: string
  version: number
  status: 'draft' | 'published' | 'archived'
}
type Category = { key: string; label: string }
type Person = { id: string; full_name: string }

const auth = useAuthStore()
const dialogs = useDialogStore()

const templates = ref<Template[]>([])
const categories = ref<Category[]>([])
const people = ref<Person[]>([])
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const editing = ref<Template | null>(null)
// Whether the editor is open at all. A new template starts empty with no row
// behind it, so neither `editing` nor the form's contents can stand in for this.
const open = ref(false)
const form = ref({ title: '', categoryKey: 'employment_agreement', body: '' })
const previewPersonId = ref('')
const previewValues = ref<Record<string, string>>({})

const mayEdit = computed(() =>
  props.companyId === null ? auth.isAdmin : auth.can(props.companyId, 'employment.edit'),
)
const live = computed(() => templates.value.filter((t) => t.status !== 'archived'))

// What the body becomes for the person picked — the whole point of a preview.
const rendered = computed(() => renderTemplate(form.value.body, previewValues.value))
const used = computed(() => placeholdersIn(form.value.body))

async function load(): Promise<void> {
  loading.value = true
  const [tplRes, catRes, peopleRes] = await Promise.all([
    supabase
      .from('contract_templates')
      .select('id, company_id, category_key, title, body, version, status')
      .order('title'),
    supabase.from('document_categories').select('key, label').eq('person_scoped', true).order('sort_order'),
    supabase.from('people').select('id, full_name').order('full_name').limit(300),
  ])
  loading.value = false
  if (tplRes.error) {
    error.value = 'Could not load the templates.'
    console.error('Contract templates load failed:', tplRes.error.message)
    return
  }
  const scope = props.companyId
  templates.value = ((tplRes.data ?? []) as Template[]).filter((t) => t.company_id === scope)
  categories.value = (catRes.data ?? []) as Category[]
  people.value = (peopleRes.data ?? []) as Person[]
}

async function loadPreviewValues(): Promise<void> {
  if (!previewPersonId.value) {
    previewValues.value = {}
    return
  }
  const { data, error: err } = await supabase.rpc('contract_values', { p_person_id: previewPersonId.value })
  previewValues.value = err ? {} : ((data ?? {}) as Record<string, string>)
}
watch(previewPersonId, loadPreviewValues)

function startNew(): void {
  editing.value = null
  open.value = true
  form.value = { title: '', categoryKey: categories.value[0]?.key ?? 'employment_agreement', body: '' }
  notice.value = null
  error.value = null
}

function edit(t: Template): void {
  editing.value = t
  open.value = true
  form.value = { title: t.title, categoryKey: t.category_key, body: t.body }
  notice.value = null
  error.value = null
}

/** Puts the placeholder where the cursor is, so nobody has to type the braces. */
function insert(key: string): void {
  form.value.body += `{{${key}}}`
}

async function save(publish: boolean): Promise<void> {
  error.value = null
  if (form.value.title.trim().length < 3) {
    error.value = 'Give the template a title.'
    return
  }
  if (form.value.body.trim() === '') {
    error.value = 'A template needs a body.'
    return
  }
  busy.value = true
  const t = editing.value
  let id = t?.id ?? null

  if (!t) {
    const { data, error: err } = await supabase
      .from('contract_templates')
      .insert({
        company_id: props.companyId,
        category_key: form.value.categoryKey,
        title: form.value.title.trim(),
        body: form.value.body,
      })
      .select('id')
      .single()
    if (err) { busy.value = false; error.value = err.message; return }
    id = data.id
  } else if (t.status === 'draft') {
    const { error: err } = await supabase
      .from('contract_templates')
      .update({ title: form.value.title.trim(), category_key: form.value.categoryKey, body: form.value.body })
      .eq('id', t.id)
    if (err) { busy.value = false; error.value = err.message; return }
  }

  if (publish && id) {
    // Publishing a published template makes the next version rather than
    // rewriting the text some contract was already issued from.
    const { error: err } = await supabase.rpc('publish_contract_template', {
      p_template_id: id,
      p_body: form.value.body,
      p_title: form.value.title.trim(),
    })
    if (err) { busy.value = false; error.value = err.message; return }
  }
  busy.value = false
  notice.value = publish ? 'Published. New contracts will use this version.' : 'Saved as a draft.'
  editing.value = null
  open.value = false
  await load()
}

async function archive(t: Template): Promise<void> {
  const sure = await dialogs.confirmAction({
    title: `Archive "${t.title}"?`,
    hint: 'It stops being offered for new contracts. Contracts already issued from it are unaffected.',
    confirmLabel: 'Archive it',
    cancelLabel: 'Keep it',
  })
  if (!sure) return
  busy.value = true
  const { error: err } = await supabase.from('contract_templates').update({ status: 'archived' }).eq('id', t.id)
  busy.value = false
  if (err) { error.value = err.message; return }
  await load()
}

onMounted(load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Contract templates</h2>
        <p>Written once, filled in per person, printed and signed by hand.</p>
      </div>
      <button v-if="mayEdit" class="button small-btn" type="button" :disabled="busy" @click="startNew">New template</button>
    </div>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <p v-if="notice" class="inline-note">{{ notice }}</p>
    <div v-if="loading" class="empty">Loading…</div>

    <template v-else>
      <div v-if="!live.length && !open" class="empty">No templates yet.</div>
      <div v-for="t in live" :key="t.id" class="tpl-row">
        <div class="row-text">
          <strong>{{ t.title }}</strong>
          <small>
            {{ categories.find((c) => c.key === t.category_key)?.label ?? t.category_key }}
            · v{{ t.version }}
            · <span :class="t.status === 'published' ? 'live' : 'draft'">{{ t.status }}</span>
          </small>
        </div>
        <div v-if="mayEdit" class="actions">
          <button class="button secondary small-btn" type="button" :disabled="busy" @click="edit(t)">
            {{ t.status === 'published' ? 'New version' : 'Edit' }}
          </button>
          <button class="button secondary small-btn" type="button" :disabled="busy" @click="archive(t)">Archive</button>
        </div>
      </div>

      <form v-if="mayEdit && open" class="editor" novalidate @submit.prevent="save(true)">
        <div class="form-title">
          {{ editing ? (editing.status === 'published' ? `New version of ${editing.title}` : `Editing ${editing.title}`) : 'New template' }}
        </div>

        <div class="top">
          <label><span>Title</span><input v-model="form.title" maxlength="120" placeholder="Employment agreement" /></label>
          <label>
            <span>Filed as</span>
            <select v-model="form.categoryKey">
              <option v-for="c in categories" :key="c.key" :value="c.key">{{ c.label }}</option>
            </select>
          </label>
        </div>

        <div class="split">
          <label class="body-label">
            <span>The contract</span>
            <textarea v-model="form.body" rows="16" spellcheck="true"></textarea>
          </label>

          <div class="side">
            <div class="fields">
              <div class="side-title">Fields you can use</div>
              <button
                v-for="f in TEMPLATE_FIELDS"
                :key="f.key"
                type="button"
                class="chip"
                :class="{ req: f.required, on: used.includes(f.key) }"
                :title="f.required ? 'Required — a contract will not issue without it' : 'Optional'"
                @click="insert(f.key)"
              >{{ f.label }}</button>
              <p class="hint">Click one to add it. Bold means required.</p>
            </div>

            <div class="preview-box">
              <div class="side-title">Preview for</div>
              <select v-model="previewPersonId">
                <option value="">Nobody — show the placeholders</option>
                <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
              </select>
              <p v-if="previewPersonId && rendered.missing.length" class="warn">
                Will not issue for them — no {{ rendered.missing.map(labelFor).join(', ') }}.
              </p>
              <p v-if="rendered.unknown.length" class="warn">
                Unknown field{{ rendered.unknown.length > 1 ? 's' : '' }}: {{ rendered.unknown.join(', ') }} — a typo?
              </p>
              <p v-else-if="previewPersonId && canIssue(rendered)" class="ok">Issues cleanly for them.</p>
              <pre class="preview">{{ rendered.text || 'The contract will appear here as you write it.' }}</pre>
            </div>
          </div>
        </div>

        <div class="form-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="open = false; editing = null">Cancel</button>
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="save(false)">Save draft</button>
          <button type="submit" class="button small-btn" :disabled="busy">Publish</button>
        </div>
      </form>
    </template>
  </div>
</template>

<style scoped>
.tpl-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.live { color: #3e744e; font-weight: 600; }
.draft { color: #8a6d1f; font-weight: 600; }
.actions { display: flex; gap: 7px; flex-wrap: wrap; }

.editor { display: grid; gap: 14px; padding: 18px 24px; border-top: 1px solid #edf0eb; background: #f7f9f5; }
.form-title { font-size: 12px; font-weight: 600; }
.top { display: grid; grid-template-columns: 2fr 1fr; gap: 12px; }
.split { display: grid; grid-template-columns: minmax(0, 1.2fr) minmax(min(240px, 100%), 1fr); gap: 16px; }
@media (max-width: 900px) { .split, .top { grid-template-columns: 1fr; } }
label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
input, select, textarea { font: inherit; font-size: 12px; padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; background: #fff; }
textarea { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; line-height: 1.6; resize: vertical; }
.side { display: grid; gap: 14px; align-content: start; }
.side-title { font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin-bottom: 6px; }
.fields { display: flex; flex-wrap: wrap; gap: 5px; }
.fields .side-title { width: 100%; }
.chip { font: inherit; font-size: 10px; padding: 4px 9px; border: 1px solid var(--line); background: #fff; border-radius: 999px; cursor: pointer; color: var(--muted); }
.chip.req { font-weight: 650; color: var(--ink); }
.chip.on { border-color: var(--green); color: var(--green); }
.hint { width: 100%; margin: 4px 0 0; font-size: 10px; color: var(--muted); }
.preview-box { display: grid; gap: 6px; }
.preview { margin: 0; padding: 12px; background: #fff; border: 1px solid var(--line); border-radius: 9px; font-size: 11px; line-height: 1.6; white-space: pre-wrap; max-height: 320px; overflow: auto; font-family: inherit; }
.warn { margin: 0; font-size: 11px; color: #a8332b; }
.ok { margin: 0; font-size: 11px; color: #3e744e; }
.form-actions { display: flex; gap: 8px; justify-content: flex-end; }
</style>
