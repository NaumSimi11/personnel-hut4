<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { assetLine, assetNumbers } from '@/lib/assetRegister'
import { assetStatusLabel, type AssignmentAction } from '@/lib/equipment'

/**
 * One line of the equipment register, wherever it is read.
 *
 * There used to be two of these — the Equipment page and the company's
 * Equipment tab each drew their own — and they drifted: one learned about
 * inventory numbers and unmatched holders and gained Edit and Delete, the other
 * kept showing a tag, a type and the word Available. Whoever opened the company
 * tab saw a poorer register with no way to correct it.
 *
 * Editing happens in place. The form used to open at the top of the page, so
 * pressing Edit on the fiftieth row appeared to do nothing at all: the fields
 * were two screens up, out of sight. A row edits where it sits.
 */
export type RowAsset = {
  id: string
  ordinal: number | null
  asset_tag: string
  inventory_number: string | null
  type_key: string
  type_note: string | null
  model: string | null
  serial_number: string | null
  note: string | null
  status: string
  company_id: string | null
  holder_note: string | null
}

export type RowEdit = {
  ordinal: string
  assetTag: string
  inventoryNumber: string
  typeKey: string
  typeNote: string
  model: string
  serialNumber: string
  note: string
}

const props = defineProps<{
  asset: RowAsset
  types: readonly { key: string; label: string }[]
  companyNames: Record<string, string>
  holderNames: Record<string, string>
  holderId: string | null
  issuedAt?: string | null
  actions: readonly AssignmentAction[]
  canEdit: boolean
  busy: boolean
  /** True briefly after a save, to show the row settled. */
  justSaved?: boolean
}>()

const emit = defineEmits<{ save: [RowEdit]; remove: []; act: [AssignmentAction] }>()

const editing = ref(false)
const form = ref<RowEdit>(blank())

function blank(): RowEdit {
  const a = props.asset
  return {
    ordinal: a.ordinal === null ? '' : String(a.ordinal),
    assetTag: a.asset_tag,
    inventoryNumber: a.inventory_number ?? '',
    typeKey: a.type_key,
    typeNote: a.type_note ?? '',
    model: a.model ?? '',
    serialNumber: a.serial_number ?? '',
    note: a.note ?? '',
  }
}

function open(): void {
  form.value = blank()
  editing.value = true
}

// A save that succeeded closes the row; the parent tells us by flashing it.
watch(() => props.justSaved, (now) => { if (now) editing.value = false })

const line = computed(() =>
  assetLine(
    {
      type_key: props.asset.type_key,
      company_id: props.asset.company_id,
      holder_id: props.holderId,
      model: props.asset.model,
      holder_note: props.asset.holder_note,
      type_note: props.asset.type_note,
    },
    { types: Object.fromEntries(props.types.map((t) => [t.key, t.label])), companies: props.companyNames, holders: props.holderNames },
  ),
)
</script>

<template>
  <div class="asset-row" :class="[asset.status, { saved: justSaved, editing }]" :data-testid="`asset-${asset.asset_tag}`">
    <template v-if="!editing">
      <div class="row-text">
        <strong>
          <span v-if="asset.ordinal !== null" class="muted">{{ asset.ordinal }}. </span>
          <router-link class="tag-link" :to="{ name: 'asset', params: { assetId: asset.id } }">{{ assetNumbers(asset) }}</router-link>
        </strong>
        <small class="register-line">{{ line }}</small>
        <small>
          {{ assetStatusLabel(asset.status) }}
          <template v-if="issuedAt"> · issued {{ issuedAt.slice(0, 10) }}</template>
          <template v-if="asset.serial_number"> · S/N {{ asset.serial_number }}</template>
          <template v-if="asset.note"> · {{ asset.note }}</template>
        </small>
      </div>
      <div class="actions">
        <button v-if="canEdit" class="button secondary small-btn" type="button" :disabled="busy" @click="open">Edit</button>
        <button v-if="canEdit" class="button secondary small-btn danger" type="button" :disabled="busy" @click="emit('remove')">Delete</button>
        <button
          v-for="action in actions"
          :key="action.key"
          class="button small-btn"
          :class="{ secondary: action.key === 'cancel' }"
          type="button"
          :disabled="busy"
          @click="emit('act', action)"
        >{{ action.label }}</button>
      </div>
    </template>

    <form v-else class="edit" novalidate @submit.prevent="emit('save', form)">
      <div class="fields">
        <label><span>No.</span><input v-model="form.ordinal" inputmode="numeric" maxlength="6" /></label>
        <label><span>Asset tag</span><input v-model="form.assetTag" maxlength="60" /></label>
        <label><span>Inventory number</span><input v-model="form.inventoryNumber" maxlength="60" /></label>
        <label>
          <span>Type</span>
          <select v-model="form.typeKey">
            <option v-for="t in types" :key="t.key" :value="t.key">{{ t.label }}</option>
          </select>
        </label>
        <label v-if="form.typeKey === 'other'"><span>What is it</span><input v-model="form.typeNote" maxlength="60" /></label>
        <label class="wide"><span>Model</span><input v-model="form.model" maxlength="120" /></label>
        <label><span>Serial number</span><input v-model="form.serialNumber" maxlength="120" /></label>
        <label class="wide"><span>Note</span><input v-model="form.note" maxlength="500" /></label>
      </div>
      <div class="actions">
        <button type="button" class="button secondary small-btn" :disabled="busy" @click="editing = false">Cancel</button>
        <button type="submit" class="button small-btn" :disabled="busy">Save</button>
      </div>
    </form>
  </div>
</template>

<style scoped>
.asset-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.asset-row.retired, .asset-row.lost { opacity: 0.6; }
.asset-row.editing { background: #f7f9f5; align-items: flex-start; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.tag-link { color: inherit; text-decoration: none; }
.tag-link:hover { text-decoration: underline; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.register-line { color: var(--ink) !important; font-weight: 500; }
.muted { font-weight: 400; color: var(--muted); }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
.button.danger { color: #a8332b; border-color: #e6c9c6; }

.edit { flex: 1; display: grid; gap: 12px; }
.fields { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(150px, 100%), 1fr)); gap: 10px; }
.fields label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.fields label.wide { grid-column: span 2; }
.fields input, .fields select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 8px; background: #fff; }

/* A save is easy to miss on a long list, so the row says so for a moment. */
.asset-row.saved { animation: settle 1.2s ease-out; }
@keyframes settle {
  0% { background: #d8ecd8; }
  60% { background: #eaf5ea; }
  100% { background: transparent; }
}
@media (prefers-reduced-motion: reduce) {
  .asset-row.saved { animation: none; background: #eaf5ea; }
}
</style>
