<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { assetHistory, type HistoryInput } from '@/lib/assetHistory'
import { assetLine, assetNumbers } from '@/lib/assetRegister'
import { assetStatusLabel } from '@/lib/equipment'
import { missingRecordMessage } from '@/lib/missingRecord'

/**
 * One asset, and everything the app knows about it.
 *
 * The register answers "what do we own"; this answers "what is this, who has
 * had it, and what has been done to it" — the questions a попис asks while
 * standing in front of the thing. So the history is the body of the page rather
 * than a tab: an asset's past is its most useful property once it is more than
 * a year old.
 *
 * Notes are written and never edited. A service history whose lines can be
 * rewritten records what somebody thinks now, not what happened then.
 */
const route = useRoute()
const auth = useAuthStore()
const dialogs = useDialogStore()
const assetId = route.params.assetId as string

type Assignment = {
  id: string
  person_id: string
  issued_at: string | null
  reserved_at: string | null
  returned_at: string | null
  return_condition: string | null
  person: { full_name: string } | null
}
type Note = {
  id: string
  kind: string
  body: string
  happened_on: string
  about_person_id: string | null
  about: { full_name: string } | null
  writer: { full_name: string } | null
}
type Asset = {
  id: string
  ordinal: number | null
  asset_tag: string
  inventory_number: string | null
  type_key: string
  type_note: string | null
  model: string | null
  serial_number: string | null
  condition: string | null
  note: string | null
  status: string
  company_id: string | null
  holder_note: string | null
  created_at: string
  asset_assignments: Assignment[]
}

const asset = ref<Asset | null>(null)
const notes = ref<Note[]>([])
const types = ref<Record<string, string>>({})
const companies = ref<Record<string, string>>({})
const loading = ref(true)
const error = ref<string | null>(null)
const busy = ref(false)

const adding = ref(false)
const noteForm = ref({ kind: 'service', body: '', happenedOn: new Date().toISOString().slice(0, 10) })

const open = computed(() => asset.value?.asset_assignments.find((a) => a.returned_at === null) ?? null)
const mayWork = computed(() =>
  asset.value ? (asset.value.company_id === null ? auth.canAnywhere('it.assign') : auth.can(asset.value.company_id, 'it.assign')) : false,
)
const holderNames = computed(() =>
  Object.fromEntries((asset.value?.asset_assignments ?? []).map((a) => [a.person_id, a.person?.full_name ?? '—'])),
)
const line = computed(() =>
  asset.value
    ? assetLine(
        {
          type_key: asset.value.type_key,
          company_id: asset.value.company_id,
          holder_id: open.value?.person_id ?? null,
          model: asset.value.model,
          holder_note: asset.value.holder_note,
          type_note: asset.value.type_note,
        },
        { types: types.value, companies: companies.value, holders: holderNames.value },
      )
    : '',
)

const history = computed(() => {
  if (!asset.value) return []
  const input: HistoryInput = {
    createdAt: asset.value.created_at,
    assignments: asset.value.asset_assignments.map((a) => ({
      issued_at: a.issued_at,
      returned_at: a.returned_at,
      person: a.person?.full_name ?? 'someone',
      return_condition: a.return_condition,
    })),
    notes: notes.value.map((n) => ({
      happened_on: n.happened_on,
      kind: n.kind,
      body: n.body,
      about: n.about?.full_name ?? null,
    })),
    transfers: [],
  }
  return assetHistory(input)
})

async function load(): Promise<void> {
  loading.value = true
  const [assetRes, noteRes, typeRes, compRes] = await Promise.all([
    supabase
      .from('assets')
      .select('*, asset_assignments(id, person_id, issued_at, reserved_at, returned_at, return_condition, person:people!asset_assignments_person_id_fkey(full_name))')
      .eq('id', assetId)
      .maybeSingle(),
    supabase
      .from('asset_notes')
      .select('id, kind, body, happened_on, about_person_id, about:people!asset_notes_about_person_id_fkey(full_name), writer:people!asset_notes_written_by_fkey(full_name)')
      .eq('asset_id', assetId)
      .order('happened_on', { ascending: false }),
    supabase.from('asset_types').select('key, label'),
    supabase.from('companies').select('id, name'),
  ])
  loading.value = false
  if (assetRes.error || !assetRes.data) {
    error.value = missingRecordMessage({
      noun: 'asset',
      lookupFailed: Boolean(assetRes.error),
      seesEverything: auth.isAdmin,
      plural: 'it',
    })
    return
  }
  asset.value = assetRes.data as unknown as Asset
  notes.value = (noteRes.data ?? []) as unknown as Note[]
  types.value = Object.fromEntries((typeRes.data ?? []).map((t) => [t.key, t.label]))
  companies.value = Object.fromEntries((compRes.data ?? []).map((c) => [c.id, c.name]))
}

async function addNote(): Promise<void> {
  if (noteForm.value.body.trim().length < 3) {
    error.value = 'Say what happened.'
    return
  }
  busy.value = true
  const { error: err } = await supabase.from('asset_notes').insert({
    asset_id: assetId,
    kind: noteForm.value.kind,
    body: noteForm.value.body.trim(),
    happened_on: noteForm.value.happenedOn,
    about_person_id: open.value?.person_id ?? null,
    written_by: auth.personId,
  })
  busy.value = false
  if (err) { error.value = err.message; return }
  adding.value = false
  noteForm.value = { kind: 'service', body: '', happenedOn: new Date().toISOString().slice(0, 10) }
  await load()
}

async function remove(): Promise<void> {
  if (!asset.value) return
  const sure = await dialogs.confirmAction({
    title: `Delete ${asset.value.asset_tag}?`,
    hint: 'Its whole history goes with it. This cannot be undone.',
    confirmLabel: 'Delete asset',
    cancelLabel: 'Keep it',
  })
  if (!sure) return
  busy.value = true
  const { error: err } = await supabase.from('assets').delete().eq('id', assetId)
  busy.value = false
  if (err) { error.value = err.message; return }
  window.location.assign('/equipment')
}

onMounted(load)
</script>

<template>
  <div>
    <router-link class="back" :to="{ name: 'equipment' }">← Back to Equipment</router-link>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-if="loading" class="empty">Loading…</div>

    <template v-else-if="asset">
      <div class="eyebrow">Equipment</div>
      <h1 class="title">{{ assetNumbers(asset) }}</h1>
      <p class="sub">{{ line }}</p>

      <section class="card facts-card">
        <dl class="facts">
          <div><dt>Status</dt><dd>{{ assetStatusLabel(asset.status) }}</dd></div>
          <div><dt>Type</dt><dd>{{ asset.type_note || types[asset.type_key] || asset.type_key }}</dd></div>
          <div><dt>Model</dt><dd>{{ asset.model || '—' }}</dd></div>
          <div><dt>Serial</dt><dd>{{ asset.serial_number || '—' }}</dd></div>
          <div><dt>No.</dt><dd>{{ asset.ordinal ?? '—' }}</dd></div>
          <div><dt>Inventory no.</dt><dd>{{ asset.inventory_number || '—' }}</dd></div>
          <div><dt>Owner</dt><dd>{{ asset.company_id ? companies[asset.company_id] : 'Shared' }}</dd></div>
          <div>
            <dt>Held by</dt>
            <dd>
              <router-link v-if="open" :to="{ name: 'person', params: { personId: open.person_id } }">
                {{ open.person?.full_name }}
              </router-link>
              <span v-else-if="asset.holder_note">{{ asset.holder_note }} <small>(from the books)</small></span>
              <span v-else>magacin</span>
            </dd>
          </div>
        </dl>
        <p v-if="asset.note" class="asset-note">{{ asset.note }}</p>
        <div v-if="mayWork" class="card-actions">
          <button class="button secondary small-btn danger" type="button" :disabled="busy" @click="remove">Delete asset</button>
        </div>
      </section>

      <section class="card">
        <div class="card-head">
          <div>
            <h2>History</h2>
            <p>Everything that has happened to this, newest first.</p>
          </div>
          <button v-if="mayWork" class="button small-btn" type="button" :disabled="busy" @click="adding = !adding">
            Add a note
          </button>
        </div>

        <form v-if="adding" class="note-form" novalidate @submit.prevent="addNote">
          <label>
            <span>What kind</span>
            <select v-model="noteForm.kind">
              <option value="service">Service or repair</option>
              <option value="damage">Damage</option>
              <option value="condition">Condition check</option>
              <option value="note">Note</option>
            </select>
          </label>
          <label><span>When</span><input v-model="noteForm.happenedOn" type="date" /></label>
          <label class="wide"><span>What happened</span><input v-model="noteForm.body" maxlength="500" placeholder="Screen replaced under warranty" /></label>
          <p class="fineprint">Notes are kept as written — a correction is a new line, as in a logbook.</p>
          <div class="form-actions">
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="adding = false">Cancel</button>
            <button type="submit" class="button small-btn" :disabled="busy">Add it</button>
          </div>
        </form>

        <ol class="history">
          <li v-for="(row, i) in history" :key="`${row.on}-${i}`" :class="row.kind">
            <span class="when">{{ row.on }}</span>
            <span class="what">{{ row.text }}</span>
          </li>
        </ol>
      </section>
    </template>
  </div>
</template>

<style scoped>
.back { display: inline-block; margin-bottom: 14px; font-size: 11px; color: var(--muted); text-decoration: none; }
.back:hover { text-decoration: underline; }
.title { margin: 4px 0 2px; }
.sub { margin: 0 0 20px; font-size: 13px; color: var(--muted); }
.facts-card { padding: 20px 24px; margin-bottom: 18px; }
.facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 16px; margin: 0; }
.facts dt { font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
.facts dd { margin: 4px 0 0; font-size: 13px; font-weight: 600; }
.facts dd small { font-weight: 400; color: var(--muted); }
.asset-note { margin: 16px 0 0; padding-top: 14px; border-top: 1px solid #edf0eb; font-size: 12px; color: var(--muted); }
.card-actions { display: flex; justify-content: flex-end; margin-top: 14px; }
.button.danger { color: #a8332b; border-color: #e6c9c6; }

.note-form { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 10px 14px; padding: 16px 24px; background: #f7f9f5; border-top: 1px solid #edf0eb; }
.note-form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.note-form label.wide { grid-column: 1 / -1; }
.note-form input, .note-form select { font: inherit; font-size: 12px; padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; background: #fff; }
.fineprint { grid-column: 1 / -1; margin: 0; font-size: 10px; color: var(--muted); }
.form-actions { grid-column: 1 / -1; display: flex; gap: 8px; justify-content: flex-end; }

.history { list-style: none; margin: 0; padding: 0; }
.history li { display: grid; grid-template-columns: 96px minmax(0, 1fr); gap: 14px; padding: 13px 24px; border-top: 1px solid #edf0eb; font-size: 12px; }
@media (max-width: 520px) { .history li { grid-template-columns: 1fr; gap: 3px; } }
.when { color: var(--muted); font-variant-numeric: tabular-nums; }
.history li.issued .what { color: #3e744e; }
.history li.returned .what { color: var(--ink); }
.history li.damage .what { color: #a8332b; }
.history li.service .what { color: #8a6d1f; }
.history li.registered .what { color: var(--muted); }
</style>
