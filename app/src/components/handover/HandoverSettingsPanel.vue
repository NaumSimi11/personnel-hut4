<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import type { Json } from '@/types/database'
import {
  EVENTS,
  canPlaceField,
  messageForHandover,
  recipientSummary,
  recipientTarget,
  type HandoverFieldDef,
  type HandoverRecipient,
} from '@/lib/handover'

/**
 * Settings → Handover (plan 048): who is told what, when, for this company.
 * A recipient is a workflow-owner role (IT, HR…), the person's manager, a
 * named colleague, or an outside address (the accountant). Sensitive
 * fields carry a lock: only a trusted recipient may receive them, and only
 * a viewer who holds personal.view / salary.view here may put them on.
 * The holding default shows underneath when the company has none of its
 * own; the first recipient added here replaces it for this company.
 */
const props = defineProps<{ companyId: string; companyName: string }>()

const auth = useAuthStore()
const dialogs = useDialogStore()
const recipients = ref<HandoverRecipient[]>([])
const catalogue = ref<HandoverFieldDef[]>([])
const roles = ref<Record<string, string>>({})
const people = ref<Record<string, string>>({})
const peopleList = ref<{ id: string; name: string }[]>([])
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const editing = ref<HandoverRecipient | null>(null)

const canEdit = computed(() => auth.can(props.companyId, 'tasks.assign'))
const own = computed(() => recipients.value.filter((r) => r.company_id === props.companyId))
const defaults = computed(() => recipients.value.filter((r) => r.company_id === null))
const shown = computed(() => (own.value.length ? own.value : defaults.value))
const usingDefault = computed(() => own.value.length === 0)

function blank(): HandoverRecipient {
  return { id: '', company_id: props.companyId, label: '', kind: 'email', role_key: null, person_id: null, email: '', events: ['hire_confirmed'], fields: ['name'], trusted: false, active: true }
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [rRes, fRes, rolesRes, peopleRes] = await Promise.all([
    supabase.from('handover_recipients').select('*').or(`company_id.eq.${props.companyId},company_id.is.null`).eq('active', true).order('sort_order'),
    supabase.rpc('handover_fields'),
    supabase.from('workflow_roles').select('key, label'),
    supabase.from('people').select('id, full_name').is('archived_at', null).order('full_name'),
  ])
  if (rRes.error || fRes.error) {
    error.value = 'Could not load the handover settings.'
    console.error('Handover settings load failed:', rRes.error?.message ?? fRes.error?.message)
  }
  recipients.value = (rRes.data ?? []) as HandoverRecipient[]
  catalogue.value = (fRes.data ?? []) as HandoverFieldDef[]
  roles.value = Object.fromEntries((rolesRes.data ?? []).map((r) => [r.key, r.label]))
  people.value = Object.fromEntries((peopleRes.data ?? []).map((p) => [p.id, p.full_name]))
  peopleList.value = (peopleRes.data ?? []).map((p) => ({ id: p.id, name: p.full_name }))
  loading.value = false
}

function startNew(): void {
  editing.value = blank()
  error.value = null
  notice.value = null
}

/** A default recipient is edited as a copy for this company; the default stays. */
function startEdit(r: HandoverRecipient): void {
  editing.value = r.company_id === props.companyId ? { ...r } : { ...r, id: '', company_id: props.companyId }
  error.value = null
  notice.value = null
}

function toggleIn(list: string[], key: string): string[] {
  return list.includes(key) ? list.filter((k) => k !== key) : [...list, key]
}

function fieldAllowed(f: HandoverFieldDef): boolean {
  return editing.value ? canPlaceField(f, editing.value, auth, props.companyId) : false
}

async function save(): Promise<void> {
  const e = editing.value
  if (!e) return
  error.value = null
  if (e.label.trim().length < 2) {
    error.value = 'Name the recipient.'
    return
  }
  if (e.kind === 'email' && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e.email ?? '')) {
    error.value = 'Enter the address.'
    return
  }
  busy.value = true
  const payload = {
    ...(e.id ? { id: e.id } : {}),
    company_id: props.companyId,
    label: e.label.trim(),
    kind: e.kind,
    role_key: e.kind === 'role' ? e.role_key : null,
    person_id: e.kind === 'person' ? e.person_id : null,
    email: e.kind === 'email' ? (e.email ?? '').trim() : null,
    events: e.events,
    fields: e.fields,
    trusted: e.trusted,
    active: true,
  }
  const { error: err } = await supabase.rpc('save_handover_recipient', { p: payload as Json })
  busy.value = false
  if (err) {
    error.value = messageForHandover(err)
    return
  }
  notice.value = e.id ? 'Recipient saved.' : `${e.label.trim()} added${usingDefault.value ? ` — ${props.companyName} now has its own handover list` : ''}.`
  editing.value = null
  await load()
}

async function remove(r: HandoverRecipient): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Stop telling ${r.label}?`,
    hint: 'Sends already made stay on record; nothing new goes to them.',
    confirmLabel: 'Remove recipient',
    danger: true,
  })
  if (!ok) return
  busy.value = true
  const { error: err } = await supabase.rpc('remove_handover_recipient', { p_id: r.id })
  busy.value = false
  if (err) {
    error.value = messageForHandover(err)
    return
  }
  await load()
}

onMounted(load)
</script>

<template>
  <div class="card" data-testid="handover-settings">
    <div class="card-head">
      <div>
        <h2>Handover</h2>
        <p>Who is told what when someone joins or leaves. Each recipient gets exactly their fields; sensitive ones only when they are trusted.</p>
      </div>
      <button v-if="canEdit && !editing" class="button secondary small-btn" type="button" data-testid="add-recipient" @click="startNew">Add recipient</button>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <div v-if="loading" class="empty">Loading handover…</div>
    <template v-else>
      <p class="source" data-testid="handover-source">
        <template v-if="usingDefault">The holding default. {{ canEdit ? 'Add or edit a recipient to make ' + companyName + "'s own list." : '' }}</template>
        <template v-else>{{ companyName }}'s own list.</template>
      </p>

      <form v-if="editing" class="editor" novalidate @submit.prevent="save">
        <div class="grid">
          <div class="field">
            <label for="hr-label">Recipient</label>
            <input id="hr-label" v-model="editing.label" maxlength="80" placeholder="e.g. Accountant" />
          </div>
          <div class="field">
            <label for="hr-kind">Who</label>
            <select id="hr-kind" v-model="editing.kind">
              <option value="email">An outside address</option>
              <option value="role">A role in this company</option>
              <option value="person">A colleague</option>
            </select>
          </div>
          <div v-if="editing.kind === 'email'" class="field">
            <label for="hr-email">Address</label>
            <input id="hr-email" v-model="editing.email" type="email" maxlength="320" />
          </div>
          <div v-else-if="editing.kind === 'role'" class="field">
            <label for="hr-role">Role</label>
            <select id="hr-role" v-model="editing.role_key">
              <option v-for="(label, key) in roles" :key="key" :value="key">{{ label }}</option>
              <option value="manager">The person's manager</option>
            </select>
          </div>
          <div v-else class="field">
            <label for="hr-person">Colleague</label>
            <select id="hr-person" v-model="editing.person_id">
              <option v-for="p in peopleList" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
          </div>
          <div class="field checkbox">
            <label><input v-model="editing.trusted" type="checkbox" data-testid="hr-trusted" /> Trusted with sensitive fields</label>
            <small class="field-hint">National ID, bank account, salary, personal contact — only to a trusted recipient.</small>
          </div>
        </div>
        <fieldset class="chips-set">
          <legend>When</legend>
          <div class="chips">
            <label v-for="ev in EVENTS" :key="ev.key" class="chip" :class="{ active: editing.events.includes(ev.key) }">
              <input type="checkbox" :checked="editing.events.includes(ev.key)" @change="editing.events = toggleIn(editing.events, ev.key)" />
              {{ ev.label }}
            </label>
          </div>
        </fieldset>
        <fieldset class="chips-set">
          <legend>What</legend>
          <div class="chips">
            <label
              v-for="f in catalogue"
              :key="f.key"
              class="chip"
              :class="{ active: editing.fields.includes(f.key), locked: !fieldAllowed(f) && !editing.fields.includes(f.key) }"
              :title="f.sensitivity === 'plain' ? '' : !editing.trusted ? 'Only a trusted recipient may receive this' : !fieldAllowed(f) ? `Needs ${f.sensitivity === 'pay' ? 'salary.view' : 'personal.view'} here` : ''"
            >
              <input
                type="checkbox"
                :checked="editing.fields.includes(f.key)"
                :disabled="!fieldAllowed(f) && !editing.fields.includes(f.key)"
                :data-testid="`field-${f.key}`"
                @change="editing.fields = toggleIn(editing.fields, f.key)"
              />
              <span v-if="f.sensitivity !== 'plain'" aria-hidden="true">🔒 </span>{{ f.label }}
            </label>
          </div>
        </fieldset>
        <div class="actions">
          <button class="button secondary" type="button" @click="editing = null">Cancel</button>
          <button class="button" type="submit" :disabled="busy" data-testid="save-recipient">{{ busy ? 'Saving…' : editing.id ? 'Save recipient' : 'Add recipient' }}</button>
        </div>
      </form>

      <div v-if="!shown.length && !editing" class="empty">Nobody is told anything yet.</div>
      <div v-for="r in shown" :key="r.id" class="recipient" :data-testid="`recipient-${r.id}`">
        <div class="text">
          <strong>{{ r.label }} <span v-if="r.trusted" class="badge amber">trusted</span></strong>
          <small>{{ recipientTarget(r, roles, people) }}</small>
          <small>{{ recipientSummary(r, catalogue) }}</small>
        </div>
        <div v-if="canEdit" class="row-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="startEdit(r)">{{ r.company_id ? 'Edit' : 'Customise' }}</button>
          <button v-if="r.company_id" type="button" class="button secondary small-btn" :disabled="busy" @click="remove(r)">Remove</button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.in-card, .notice { margin: 14px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.source { margin: 12px 24px 4px; font-size: 11px; color: var(--muted); }
.editor { padding: 14px 24px 18px; border-top: 1px solid #edf0eb; background: #fafbf8; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 620px) { .grid { grid-template-columns: 1fr; } }
.field.checkbox label { display: flex; align-items: center; gap: 8px; font-weight: 600; }
.field.checkbox input { width: auto; }
.field-hint { font-size: 11px; color: var(--muted); }
.chips-set { border: 0; padding: 0; margin: 0 0 12px; }
.chips-set legend { font-size: 12px; font-weight: 600; color: #4d5e57; margin-bottom: 6px; }
.chips { display: flex; gap: 6px; flex-wrap: wrap; }
.chip { display: inline-flex; align-items: center; gap: 5px; border: 1px solid var(--line); background: #fff; color: var(--muted); font-size: 11px; padding: 5px 10px; border-radius: 999px; cursor: pointer; }
.chip input { width: auto; margin: 0; }
.chip.active { background: var(--green); border-color: var(--green); color: #fff; }
.chip.locked { opacity: 0.5; cursor: not-allowed; }
.actions { display: flex; gap: 9px; justify-content: flex-end; }
.recipient { display: flex; align-items: center; gap: 13px; padding: 12px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.text { flex: 1; min-width: 220px; }
.text strong { display: flex; align-items: center; gap: 8px; font-size: 12px; font-weight: 550; }
.text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.row-actions { display: flex; gap: 7px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
