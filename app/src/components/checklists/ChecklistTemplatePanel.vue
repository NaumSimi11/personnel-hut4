<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import type { Json } from '@/types/database'
import {
  OWNER_ROLES,
  PHASES_FOR,
  emptyTemplateLine,
  lineInput,
  messageForChecklist,
  moved,
  ownerLabel,
  whenLabel,
  type ChecklistKind,
  type Phase,
  type TemplateLineForm,
} from '@/lib/checklists'

/**
 * Settings → Checklists (plan 047): the onboarding and offboarding
 * templates this company's checklists start from. A company without its
 * own shows the holding default read-only with "Customise" (copy-on-write
 * through company_template); lines are added, edited, moved and retired
 * through the 0040 RPCs. Editing never touches checklists already running.
 */
const props = defineProps<{ companyId: string; companyName: string }>()

type Line = {
  id: string
  title: string
  description: string | null
  default_owner_role: string
  phase_key: string
  due_offset_days: number
  critical: boolean
  requires_evidence: boolean
  sort_order: number
  key: string | null
}
type Template = { id: string; company_id: string | null; name: string }

const auth = useAuthStore()
const dialogs = useDialogStore()
const kind = ref<ChecklistKind>('onboarding')
const template = ref<Template | null>(null)
const lines = ref<Line[]>([])
const phases = ref<Phase[]>([])
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const editingId = ref<string | null>(null)
const form = ref<TemplateLineForm>(emptyTemplateLine('onboarding'))
const showNew = ref(false)

const canEdit = computed(() => auth.can(props.companyId, 'tasks.assign'))
const isOwn = computed(() => template.value?.company_id === props.companyId)
const phaseOptions = computed(() => phases.value.filter((p) => PHASES_FOR[kind.value].includes(p.key)))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data: templates, error: tErr } = await supabase
    .from('task_templates')
    .select('id, company_id, name')
    .eq('kind', kind.value)
    .eq('active', true)
    .or(`company_id.eq.${props.companyId},company_id.is.null`)
    .order('company_id', { nullsFirst: false })
    .order('created_at')
  if (tErr) {
    error.value = 'Could not load the checklist template.'
    console.error('Template load failed:', tErr.message)
    loading.value = false
    return
  }
  // The company's own first, else the holding default (same rule as app.template_for).
  template.value = (templates ?? []).find((t) => t.company_id === props.companyId) ?? (templates ?? []).find((t) => t.company_id === null) ?? null
  if (template.value) {
    const { data, error: lErr } = await supabase
      .from('template_tasks')
      .select('id, title, description, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order, key')
      .eq('template_id', template.value.id)
      .is('archived_at', null)
      .order('sort_order')
    if (lErr) {
      error.value = 'Could not load the checklist lines.'
      console.error('Template lines load failed:', lErr.message)
    }
    lines.value = (data ?? []) as Line[]
  } else {
    lines.value = []
  }
  if (!phases.value.length) {
    const { data } = await supabase.from('plan_phases').select('key, label, sort_order').order('sort_order')
    phases.value = (data ?? []) as Phase[]
  }
  loading.value = false
}

/** The company's own copy, made from the default the first time. */
async function ensureOwn(): Promise<string | null> {
  if (isOwn.value && template.value) return template.value.id
  const { data, error: err } = await supabase.rpc('company_template', { p_company_id: props.companyId, p_kind: kind.value })
  if (err) {
    error.value = messageForChecklist(err)
    return null
  }
  const result = data as { template_id: string; created: boolean }
  if (result.created) notice.value = `${props.companyName} now has its own ${kind.value} checklist; the holding default is unchanged.`
  await load()
  return result.template_id
}

function startNew(): void {
  form.value = emptyTemplateLine(kind.value)
  editingId.value = null
  showNew.value = true
  error.value = null
}

function startEdit(line: Line): void {
  form.value = {
    title: line.title,
    description: line.description ?? '',
    ownerRole: line.default_owner_role,
    phaseKey: line.phase_key,
    dueOffsetDays: line.due_offset_days,
    critical: line.critical,
    requiresEvidence: line.requires_evidence,
  }
  editingId.value = line.id
  showNew.value = false
  error.value = null
}

function cancelEdit(): void {
  editingId.value = null
  showNew.value = false
}

/**
 * The same line on the company's own copy. When the copy has just been made,
 * ids differ; a keyed line is matched by key, an unkeyed one by title.
 */
function ownLineFor(original: Line | null): Line | null {
  if (!original) return null
  return lines.value.find((l) => (original.key ? l.key === original.key : !l.key && l.title === original.title)) ?? null
}

async function save(): Promise<void> {
  error.value = null
  notice.value = null
  const parsed = lineInput(kind.value).safeParse({ ...form.value, dueOffsetDays: Number(form.value.dueOffsetDays) })
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the line.'
    return
  }
  // Remember which line is edited before the copy reloads the list with new ids.
  const wasEditing = editingId.value !== null
  const original = lines.value.find((l) => l.id === editingId.value) ?? null
  busy.value = true
  const templateId = await ensureOwn()
  if (!templateId) {
    busy.value = false
    return
  }
  const own = ownLineFor(original)
  if (wasEditing && !own) {
    busy.value = false
    error.value = 'That line is no longer on the checklist.'
    return
  }
  const payload: Record<string, unknown> = {
    template_id: templateId,
    ...(own ? { id: own.id } : {}),
    title: parsed.data.title,
    description: parsed.data.description,
    owner_role: parsed.data.ownerRole,
    phase_key: parsed.data.phaseKey,
    due_offset_days: parsed.data.dueOffsetDays,
    critical: parsed.data.critical,
    requires_evidence: parsed.data.requiresEvidence,
  }
  const { error: err } = await supabase.rpc('upsert_template_task', { p: payload as Json })
  busy.value = false
  if (err) {
    error.value = messageForChecklist(err)
    return
  }
  cancelEdit()
  notice.value = wasEditing ? 'Line saved.' : 'Line added.'
  await load()
}

async function retire(line: Line): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Remove "${line.title}" from new checklists?`,
    hint: 'Checklists already running keep it. The line can be added again later.',
    confirmLabel: 'Remove line',
    danger: true,
  })
  if (!ok) return
  busy.value = true
  error.value = null
  const templateId = await ensureOwn()
  if (!templateId) {
    busy.value = false
    return
  }
  const target = ownLineFor(line)
  if (!target) {
    busy.value = false
    error.value = 'That line is no longer on the checklist.'
    return
  }
  const { error: err } = await supabase.rpc('retire_template_task', { p_id: target.id })
  busy.value = false
  if (err) {
    error.value = messageForChecklist(err)
    return
  }
  await load()
}

async function move(line: Line, direction: -1 | 1): Promise<void> {
  busy.value = true
  error.value = null
  const templateId = await ensureOwn()
  if (!templateId) {
    busy.value = false
    return
  }
  const target = ownLineFor(line)
  if (!target) {
    busy.value = false
    error.value = 'That line is no longer on the checklist.'
    return
  }
  const ids = moved(
    lines.value.map((l) => l.id),
    target.id,
    direction,
  )
  const { error: err } = await supabase.rpc('reorder_template_tasks', { p_template_id: templateId, p_ids: ids })
  busy.value = false
  if (err) {
    error.value = messageForChecklist(err)
    return
  }
  await load()
}

watch(kind, () => {
  cancelEdit()
  notice.value = null
  void load()
})
onMounted(load)
</script>

<template>
  <div class="card" data-testid="checklist-template-panel">
    <div class="card-head">
      <div>
        <h2>Checklists</h2>
        <p>What every new checklist starts from. Editing never changes a checklist already running.</p>
      </div>
      <div class="kinds" role="tablist" aria-label="Checklist kind">
        <button type="button" class="chip" :class="{ active: kind === 'onboarding' }" role="tab" :aria-selected="kind === 'onboarding'" @click="kind = 'onboarding'">Onboarding</button>
        <button type="button" class="chip" :class="{ active: kind === 'offboarding' }" role="tab" :aria-selected="kind === 'offboarding'" @click="kind = 'offboarding'">Offboarding</button>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <div v-if="loading" class="empty">Loading checklist…</div>
    <template v-else>
      <p class="source" data-testid="template-source">
        <template v-if="isOwn">{{ companyName }}'s own {{ kind }} checklist.</template>
        <template v-else>The holding default. {{ canEdit ? `The first change makes ${companyName}'s own copy.` : '' }}</template>
      </p>
      <div v-if="!lines.length" class="empty">No lines yet.</div>
      <div v-for="(line, i) in lines" :key="line.id" class="line" :data-testid="`template-line-${line.id}`">
        <template v-if="editingId === line.id">
          <form class="edit" novalidate @submit.prevent="save">
            <input v-model="form.title" maxlength="160" aria-label="Title" class="wide" />
            <select v-model="form.ownerRole" aria-label="Owner">
              <option v-for="o in OWNER_ROLES" :key="o.key" :value="o.key">{{ o.label }}</option>
            </select>
            <select v-model="form.phaseKey" aria-label="Phase">
              <option v-for="p in phaseOptions" :key="p.key" :value="p.key">{{ p.label }}</option>
            </select>
            <input v-model.number="form.dueOffsetDays" type="number" min="-60" max="120" aria-label="Days relative" class="days" />
            <label class="check"><input v-model="form.critical" type="checkbox" /> Required</label>
            <label class="check"><input v-model="form.requiresEvidence" type="checkbox" /> Evidence</label>
            <button class="button small-btn" type="submit" :disabled="busy">Save</button>
            <button class="button secondary small-btn" type="button" @click="cancelEdit">Cancel</button>
          </form>
        </template>
        <template v-else>
          <span class="n">{{ i + 1 }}</span>
          <div class="text">
            <strong>{{ line.title }}</strong>
            <small>{{ ownerLabel(line.default_owner_role) }} · {{ whenLabel(line.phase_key, line.due_offset_days, kind) }}<template v-if="line.critical"> · required</template><template v-if="line.requires_evidence"> · evidence</template></small>
            <small v-if="line.description" class="desc">{{ line.description }}</small>
          </div>
          <div v-if="canEdit" class="actions">
            <button type="button" class="icon-btn" :disabled="busy || i === 0" aria-label="Move up" @click="move(line, -1)">↑</button>
            <button type="button" class="icon-btn" :disabled="busy || i === lines.length - 1" aria-label="Move down" @click="move(line, 1)">↓</button>
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="startEdit(line)">Edit</button>
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="retire(line)">Remove</button>
          </div>
        </template>
      </div>
      <div v-if="canEdit" class="add">
        <button v-if="!showNew" type="button" class="button secondary small-btn" data-testid="add-template-line" @click="startNew">Add a line</button>
        <form v-else class="edit" novalidate @submit.prevent="save">
          <input id="tl-title" v-model="form.title" maxlength="160" placeholder="What has to be done" aria-label="Title" class="wide" />
          <select id="tl-owner" v-model="form.ownerRole" aria-label="Owner">
            <option v-for="o in OWNER_ROLES" :key="o.key" :value="o.key">{{ o.label }}</option>
          </select>
          <select id="tl-phase" v-model="form.phaseKey" aria-label="Phase">
            <option v-for="p in phaseOptions" :key="p.key" :value="p.key">{{ p.label }}</option>
          </select>
          <input id="tl-days" v-model.number="form.dueOffsetDays" type="number" min="-60" max="120" aria-label="Days relative" class="days" />
          <label class="check"><input id="tl-critical" v-model="form.critical" type="checkbox" /> Required</label>
          <label class="check"><input v-model="form.requiresEvidence" type="checkbox" /> Evidence</label>
          <button class="button small-btn" type="submit" :disabled="busy">Add line</button>
          <button class="button secondary small-btn" type="button" @click="cancelEdit">Cancel</button>
        </form>
      </div>
    </template>
  </div>
</template>

<style scoped>
.kinds { display: flex; gap: 6px; }
.chip { border: 1px solid var(--line); background: #fff; color: var(--muted); font-size: 11px; padding: 6px 11px; border-radius: 999px; cursor: pointer; }
.chip.active { background: var(--green); border-color: var(--green); color: #fff; }
.in-card, .notice { margin: 14px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.source { margin: 12px 24px 4px; font-size: 11px; color: var(--muted); }
.line { display: flex; align-items: center; gap: 12px; padding: 12px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.n { font-size: 11px; color: var(--muted); width: 18px; }
.text { flex: 1; min-width: 220px; }
.text strong { display: block; font-size: 12px; font-weight: 550; }
.text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.text .desc { color: var(--ink); opacity: 0.75; }
.actions { display: flex; gap: 6px; align-items: center; }
.icon-btn { border: 1px solid var(--line); background: #fff; border-radius: 6px; width: 28px; height: 28px; cursor: pointer; font-size: 12px; }
.icon-btn:disabled { opacity: 0.4; cursor: default; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.add { padding: 12px 24px 16px; border-top: 1px solid #edf0eb; }
.edit { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; width: 100%; }
.edit input, .edit select { border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; background: #fff; }
.edit .wide { flex: 1 1 240px; min-width: 200px; }
.edit .days { width: 72px; }
.check { display: flex; align-items: center; gap: 5px; font-size: 11px; color: var(--muted); }
</style>
