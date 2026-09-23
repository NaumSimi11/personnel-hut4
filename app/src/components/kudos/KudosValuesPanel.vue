<script setup lang="ts">
import { ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { kudosValueInput, type KudosValue } from '@/lib/kudos'
import type { Json } from '@/types/database'

/**
 * The holding's kudos values (plan 051): what HR wants to recognise and
 * count. Admins add, edit and retire them; a retired value keeps its name
 * on the kudos already tagged with it and disappears from the pickers.
 * The counts come with the overview the page loaded.
 */
const props = defineProps<{ values: KudosValue[]; canEdit: boolean }>()
const emit = defineEmits<{ changed: [] }>()

const editingId = ref<string | null>(null)
const adding = ref(false)
const form = ref({ name: '', description: '', active: true })
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

function startAdd(): void {
  form.value = { name: '', description: '', active: true }
  editingId.value = null
  adding.value = true
  error.value = null
  notice.value = null
}

function startEdit(v: KudosValue): void {
  form.value = { name: v.name, description: v.description ?? '', active: v.active }
  editingId.value = v.id
  adding.value = false
  error.value = null
  notice.value = null
}

function cancel(): void {
  editingId.value = null
  adding.value = false
}

async function save(id: string | null, data: { name: string; description: string; active: boolean }): Promise<boolean> {
  busy.value = true
  error.value = null
  // p_id is a uuid with no default, so a null means "make a new one" — which the
  // generated types cannot say, since they type every uuid argument as a string.
  const { error: err } = await supabase.rpc('save_kudos_value', { p_id: id as string, p: data as unknown as Json })
  busy.value = false
  if (err) {
    error.value = err.code === '42501' ? 'Only an admin shapes the kudos values.' : err.message
    console.error('Kudos value save failed:', err.message)
    return false
  }
  emit('changed')
  return true
}

async function submit(): Promise<void> {
  const parsed = kudosValueInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  const ok = await save(editingId.value, parsed.data)
  if (!ok) return
  notice.value = editingId.value ? 'Value saved.' : `"${parsed.data.name}" added.`
  cancel()
}

async function toggle(v: KudosValue): Promise<void> {
  const ok = await save(v.id, { name: v.name, description: v.description ?? '', active: !v.active })
  if (ok) notice.value = v.active ? `"${v.name}" retired; kudos already tagged keep it.` : `"${v.name}" is active again.`
}
</script>

<template>
  <div class="card" data-testid="kudos-values-panel">
    <div class="card-head">
      <div>
        <h2>Kudos values</h2>
        <p>What the holding recognises through kudos. A retired value stays on the kudos it already tags.</p>
      </div>
      <button v-if="canEdit && !adding" class="button small-btn" type="button" data-testid="kudos-value-add" @click="startAdd">Add value</button>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>

    <form v-if="adding" class="form" novalidate data-testid="kudos-value-form" @submit.prevent="submit">
      <label><span>Name</span><input id="kv-name" v-model="form.name" maxlength="60" autofocus /></label>
      <label class="wide"><span>Description</span><input id="kv-description" v-model="form.description" maxlength="300" placeholder="What it looks like when someone lives it" /></label>
      <div class="form-actions">
        <button type="button" class="button secondary small-btn" :disabled="busy" @click="cancel">Cancel</button>
        <button type="submit" class="button small-btn" :disabled="busy">{{ busy ? 'Saving…' : 'Add' }}</button>
      </div>
    </form>

    <div v-if="!values.length" class="empty">No values yet.</div>
    <template v-for="v in props.values" :key="v.id">
      <form v-if="editingId === v.id" class="form" novalidate @submit.prevent="submit">
        <label><span>Name</span><input v-model="form.name" maxlength="60" autofocus /></label>
        <label class="wide"><span>Description</span><input v-model="form.description" maxlength="300" /></label>
        <div class="form-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="cancel">Cancel</button>
          <button type="submit" class="button small-btn" :disabled="busy">{{ busy ? 'Saving…' : 'Save' }}</button>
        </div>
      </form>
      <div v-else class="value-row" :class="{ retired: !v.active }" data-testid="kudos-value-row">
        <div class="row-text">
          <strong>{{ v.name }} <span v-if="!v.active" class="muted">· retired</span></strong>
          <small>{{ v.description || '—' }}</small>
        </div>
        <span class="count">{{ v.count ?? 0 }} kudos</span>
        <div v-if="canEdit" class="actions">
          <button class="linkish" type="button" :disabled="busy" @click="startEdit(v)">Edit</button>
          <button class="linkish" type="button" :disabled="busy" @click="toggle(v)">{{ v.active ? 'Retire' : 'Reactivate' }}</button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.in-card, .notice { margin: 12px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.value-row { display: flex; align-items: center; gap: 13px; padding: 11px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.value-row.retired { opacity: 0.65; }
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.muted { font-weight: 400; color: var(--muted); }
.count { font-size: 11px; color: var(--muted); white-space: nowrap; }
.actions { display: flex; gap: 10px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.form { display: grid; grid-template-columns: 1fr 2fr; gap: 10px 14px; padding: 14px 24px; background: #fafbf8; border-top: 1px solid var(--line); }
.form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.form label.wide { grid-column: 1 / -1; }
.form .form-actions { grid-column: 1 / -1; display: flex; justify-content: flex-end; gap: 8px; }
.form input { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
@media (max-width: 560px) { .form { grid-template-columns: 1fr; } }
</style>
