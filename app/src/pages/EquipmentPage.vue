<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { deliverNotifications } from '@/lib/notificationsApi'
import CompanyFilter from '@/components/CompanyFilter.vue'
import {
  RETURN_STATUSES,
  assetInput,
  assetStatusLabel,
  assignmentActions,
  ownerLabel,
  type AssignmentAction,
} from '@/lib/equipment'
import { assetLine, assetNumbers, holderChoice, NOBODY, OTHER_HOLDER } from '@/lib/assetRegister'
import { nextAssetTag, nextInventoryNumber } from '@/lib/assetNumbering'

/**
 * Equipment across the holding (plan 049): every asset the viewer may see —
 * the holding's pool (no company) and the companies where they hold
 * it.view — with the shared company filter. An asset is added to the pool
 * or to a company; a pool asset goes to anyone employed anywhere, a
 * company asset to that company's people (reserve_asset decides). Issuing
 * queues the handover form; the delivery kick makes it.
 */
type Assignment = { id: string; person_id: string; reserved_at: string | null; issued_at: string | null; returned_at: string | null; person: { full_name: string } | null }
type Asset = {
  id: string
  company_id: string | null
  asset_tag: string
  ordinal: number | null
  inventory_number: string | null
  holder_note: string | null
  type_key: string
  model: string | null
  serial_number: string | null
  condition: string | null
  status: string
  location_id: string | null
  note: string | null
  asset_assignments: Assignment[]
}
type Person = { id: string; full_name: string; company_ids: string[] }

const POOL = '__pool__'

const auth = useAuthStore()
const dialogs = useDialogStore()
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const assets = ref<Asset[]>([])
const people = ref<Person[]>([])
const companies = ref<{ id: string; name: string }[]>([])
const types = ref<{ key: string; label: string }[]>([])
const filter = ref('')
const addingAsset = ref(false)
const assetForm = ref({ ownerId: POOL, ordinal: '', assetTag: '', inventoryNumber: '', typeKey: '', model: '', serialNumber: '', note: '' })
const editingAsset = ref<Asset | null>(null)
const reserving = ref<Asset | null>(null)
const reservePersonId = ref('')
const returning = ref<Asset | null>(null)
const returnForm = ref({ condition: '', status: 'available' })

const companyNames = computed(() => Object.fromEntries(companies.value.map((c) => [c.id, c.name])))
const canAssignAnywhere = computed(() => auth.canAnywhere('it.assign'))
// Where the viewer may add: the pool (it.assign anywhere) and each company where they hold it.assign.
const ownerOptions = computed(() => [
  ...(canAssignAnywhere.value ? [{ id: POOL, name: 'Holding pool' }] : []),
  ...companies.value.filter((c) => auth.can(c.id, 'it.assign')),
])
const filterOptions = computed(() => [{ id: POOL, name: 'Holding pool' }, ...companies.value])
const shown = computed(() => {
  const list = filter.value === '' ? assets.value : filter.value === POOL ? assets.value.filter((a) => a.company_id === null) : assets.value.filter((a) => a.company_id === filter.value)
  return [...list].sort((a, b) => a.asset_tag.localeCompare(b.asset_tag))
})
const openAssignment = (a: Asset) => a.asset_assignments.find((x) => x.returned_at === null) ?? null
const typeNames = computed(() => Object.fromEntries(types.value.map((t) => [t.key, t.label])))
// Only assets with a live (unreturned) assignment have a holder; that name comes
// off the row's own join, so the register reads right even for someone the
// employment-periods query has already dropped (a departure mid-handover).
const holderNames = computed(() =>
  Object.fromEntries(
    assets.value.flatMap((a) => {
      const open = openAssignment(a)
      return open ? [[open.person_id, open.person?.full_name ?? 'someone']] : []
    }),
  ),
)
/** The holding-wide register line: category · company · model · holder, "magacin" when unheld. */
const registerLine = (a: Asset) =>
  assetLine(
    { type_key: a.type_key, company_id: a.company_id, holder_id: openAssignment(a)?.person_id ?? null, model: a.model, holder_note: a.holder_note },
    { types: typeNames.value, companies: companyNames.value, holders: holderNames.value },
  )
function canFor(a: Asset): (cap: string) => boolean {
  return (cap) => (a.company_id === null ? auth.canAnywhere(cap) : auth.can(a.company_id, cap))
}
const actionsFor = (a: Asset): AssignmentAction[] => assignmentActions(a, openAssignment(a), canFor(a))
/** Who a given asset may go to: anyone employed for the pool, the company's people for a company asset. */
const ownedBy = (ownerId: string) =>
  assets.value.filter((a) => (ownerId === POOL ? a.company_id === null : a.company_id === ownerId))
const suggestedTag = (ownerId: string) => nextAssetTag(ownedBy(ownerId).map((a) => a.asset_tag))
const suggestedInventory = (ownerId: string) => nextInventoryNumber(ownedBy(ownerId).map((a) => a.inventory_number))
const suggestedOrdinal = (ownerId: string) => {
  const used = ownedBy(ownerId).map((a) => a.ordinal).filter((n): n is number => typeof n === 'number')
  return used.length ? Math.max(...used) + 1 : null
}

/** Opens the same form on an existing asset, so adding and editing stay one thing. */
function editAsset(a: Asset): void {
  error.value = null
  notice.value = null
  editingAsset.value = a
  addingAsset.value = true
  assetForm.value = {
    ownerId: a.company_id ?? POOL,
    ordinal: a.ordinal === null ? '' : String(a.ordinal),
    assetTag: a.asset_tag,
    inventoryNumber: a.inventory_number ?? '',
    typeKey: a.type_key,
    model: a.model ?? '',
    serialNumber: a.serial_number ?? '',
    note: a.note ?? '',
  }
}

async function removeAsset(a: Asset): Promise<void> {
  const sure = await dialogs.confirmAction({
    title: `Delete ${a.asset_tag}?`,
    hint: `${a.model ?? 'This asset'} and its whole history go with it. This cannot be undone.`,
    confirmLabel: 'Delete asset',
    cancelLabel: 'Keep it',
  })
  if (!sure) return
  const ok = await run('Delete asset', () => supabase.from('assets').delete().eq('id', a.id))
  if (ok) notice.value = `${a.asset_tag} deleted.`
}


const reserveOther = ref('')
const candidatesFor = (a: Asset): Person[] => (a.company_id === null ? people.value : people.value.filter((p) => p.company_ids.includes(a.company_id as string)))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [assetRes, peopleRes, companiesRes, typeRes] = await Promise.all([
    supabase.from('assets').select('*, asset_assignments(id, person_id, reserved_at, issued_at, returned_at, person:people!asset_assignments_person_id_fkey(full_name))'),
    supabase.from('employment_periods').select('company_id, status, person:people!employment_periods_person_id_fkey(id, full_name)').neq('status', 'former'),
    supabase.from('companies').select('id, name').is('archived_at', null).order('name'),
    supabase.from('asset_types').select('key, label').is('archived_at', null),
  ])
  loading.value = false
  if (assetRes.error) {
    error.value = 'Could not load equipment.'
    console.error('Equipment load failed:', assetRes.error.message)
    return
  }
  assets.value = (assetRes.data ?? []) as unknown as Asset[]
  const seen = new Map<string, Person>()
  for (const row of peopleRes.data ?? []) {
    const p = row.person as unknown as { id: string; full_name: string } | null
    if (!p) continue
    const existing = seen.get(p.id)
    if (existing) seen.set(p.id, { ...existing, company_ids: [...existing.company_ids, row.company_id] })
    else seen.set(p.id, { id: p.id, full_name: p.full_name, company_ids: [row.company_id] })
  }
  people.value = [...seen.values()].sort((a, b) => a.full_name.localeCompare(b.full_name))
  companies.value = companiesRes.data ?? []
  types.value = typeRes.data ?? []
}

function friendly(message: string): string {
  if (/row-level security|it\.assign/.test(message)) return 'You need it.assign here.'
  if (/it\.complete/.test(message)) return 'You need it.complete (or it.assign) here.'
  if (/assets_company_id_asset_tag_key/.test(message)) return 'An asset with this tag already exists there.'
  return message
}

async function run(label: string, fn: () => PromiseLike<{ error: { message: string } | null }>): Promise<boolean> {
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err } = await fn()
  busy.value = false
  if (err) {
    error.value = friendly(err.message)
    console.error(`${label} failed:`, err.message)
    return false
  }
  await load()
  return true
}

function startAsset(): void {
  const owner = ownerOptions.value[0]?.id ?? POOL
  assetForm.value = {
    ownerId: owner,
    // Where the company's own series got to. Only a suggestion — the label on
    // the box is the authority, and whoever knows better overwrites it.
    ordinal: String(suggestedOrdinal(owner) ?? ''),
    assetTag: suggestedTag(owner) ?? '',
    inventoryNumber: suggestedInventory(owner) ?? '',
    typeKey: types.value[0]?.key ?? '',
    model: '',
    serialNumber: '',
    note: '',
  }
  error.value = null
  addingAsset.value = true
}

async function saveAsset(): Promise<void> {
  const parsed = assetInput.safeParse({ ...assetForm.value, locationId: '' })
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  const fields = {
    company_id: assetForm.value.ownerId === POOL ? null : assetForm.value.ownerId,
    ordinal: parsed.data.ordinal,
    asset_tag: parsed.data.assetTag,
    inventory_number: parsed.data.inventoryNumber,
    type_key: parsed.data.typeKey,
    model: parsed.data.model || null,
    serial_number: parsed.data.serialNumber || null,
    note: parsed.data.note || null,
  }
  const target = editingAsset.value

  const ok = await run(target ? 'Save asset' : 'Asset insert', async () => {
    if (target) {
      const { error: err } = await supabase.from('assets').update(fields).eq('id', target.id)
      return { error: err }
    }
    const { data, error: err } = await supabase.from('assets').insert(fields).select('id').maybeSingle()
    return { error: err ?? (data ? null : { message: 'row-level security' }) }
  })
  if (ok) {
    notice.value = target ? `${fields.asset_tag} saved.` : `${fields.asset_tag} added.`
    addingAsset.value = false
    editingAsset.value = null
  }
}

function act(asset: Asset, action: AssignmentAction): void {
  error.value = null
  notice.value = null
  if (action.key === 'reserve') {
    reserving.value = asset
    reservePersonId.value = candidatesFor(asset)[0]?.id ?? ''
    reserveOther.value = asset.holder_note ?? ''
    if (asset.holder_note) reservePersonId.value = OTHER_HOLDER
    return
  }
  if (action.key === 'return') {
    returning.value = asset
    returnForm.value = { condition: '', status: 'available' }
    return
  }
  const open = openAssignment(asset)
  if (!open) return
  if (action.key === 'issue') {
    void run('Issue', () => supabase.rpc('issue_asset', { p_assignment_id: open.id })).then((ok) => {
      if (ok) {
        notice.value = `${asset.asset_tag} issued. The handover form is being made under the person's documents.`
        void deliverNotifications()
      }
    })
  }
  if (action.key === 'cancel') void run('Cancel reservation', () => supabase.rpc('cancel_reservation', { p_assignment_id: open.id }))
}

async function confirmReserve(): Promise<void> {
  if (!reserving.value) return
  const asset = reserving.value
  const choice = holderChoice(reservePersonId.value, reserveOther.value)

  if (choice.kind === 'invalid') {
    error.value = choice.message
    return
  }
  // "Other" and "nobody" are not assignments — there is no person to reserve
  // for. They record what the register should say instead, so an asset someone
  // has never reads as sitting in the warehouse.
  if (choice.kind === 'other' || choice.kind === 'nobody') {
    const holder_note = choice.kind === 'other' ? choice.text : null
    const ok = await run('Record the holder', () =>
      supabase.from('assets').update({ holder_note }).eq('id', asset.id),
    )
    if (ok) {
      reserving.value = null
      notice.value = holder_note
        ? `${asset.asset_tag} is recorded as held by ${holder_note}.`
        : `${asset.asset_tag} is back in magacin.`
    }
    return
  }
  const ok = await run('Reserve', () => supabase.rpc('reserve_asset', { p_asset_id: asset.id, p_person_id: choice.personId }))
  if (ok) reserving.value = null
}

async function confirmReturn(): Promise<void> {
  if (!returning.value) return
  const open = openAssignment(returning.value)
  if (!open) return
  const ok = await run('Return', () => supabase.rpc('return_asset', { p_assignment_id: open.id, p_condition: returnForm.value.condition || undefined, p_status: returnForm.value.status }))
  if (ok) returning.value = null
}

onMounted(load)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">Equipment</div>
        <h1>Every laptop, phone and licence across the holding.</h1>
        <p class="page-sub">The holding's pool goes to anyone employed anywhere; a company's assets stay with its people. Issuing makes the handover form; a scheduled departure makes the return form.</p>
      </div>
      <button v-if="ownerOptions.length && !addingAsset" class="button" type="button" data-testid="add-asset" @click="startAsset">Add asset</button>
    </div>
    <div v-if="notice" class="notice" role="status">{{ notice }}</div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>

    <div class="card">
      <div class="card-head">
        <div>
          <h2>Register</h2>
          <p>Reserved for a person, issued, returned. Status follows the handovers.</p>
        </div>
        <CompanyFilter v-model="filter" :companies="filterOptions" all-label="Everywhere" />
      </div>
      <div v-if="loading" class="empty">Loading…</div>
      <template v-else>
        <form v-if="addingAsset" class="form" novalidate @submit.prevent="saveAsset">
          <label>
            <span>Belongs to</span>
            <select id="asset-owner" v-model="assetForm.ownerId" @change="assetForm.assetTag = suggestedTag(assetForm.ownerId) ?? ''; assetForm.inventoryNumber = suggestedInventory(assetForm.ownerId) ?? ''">
              <option v-for="o in ownerOptions" :key="o.id" :value="o.id">{{ o.name }}</option>
            </select>
          </label>
          <label><span>ред. бр.</span><input id="asset-ordinal" v-model="assetForm.ordinal" inputmode="numeric" maxlength="6" /></label>
          <label><span>Шифра (asset tag)</span><input id="asset-tag" v-model="assetForm.assetTag" maxlength="60" /></label>
          <label>
            <span>Инв. бр. (inventory number)</span>
            <input id="asset-inventory" v-model="assetForm.inventoryNumber" maxlength="60" />
          </label>
          <label>
            <span>Type</span>
            <select id="asset-type" v-model="assetForm.typeKey">
              <option v-for="t in types" :key="t.key" :value="t.key">{{ t.label }}</option>
            </select>
          </label>
          <label><span>Model</span><input id="asset-model" v-model="assetForm.model" maxlength="120" /></label>
          <label><span>Serial number</span><input id="asset-serial" v-model="assetForm.serialNumber" maxlength="120" /></label>
          <label><span>Note</span><input id="asset-note" v-model="assetForm.note" /></label>
          <div class="form-actions">
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="addingAsset = false; editingAsset = null">Cancel</button>
            <button type="submit" class="button small-btn" :disabled="busy">{{ editingAsset ? 'Save changes' : 'Save asset' }}</button>
          </div>
        </form>

        <form v-if="reserving" class="form inline" novalidate @submit.prevent="confirmReserve">
          <div class="form-title">Who has {{ reserving.asset_tag }}</div>
          <label>
            <span>Holder</span>
            <select id="reserve-person" v-model="reservePersonId">
              <option v-for="p in candidatesFor(reserving)" :key="p.id" :value="p.id">{{ p.full_name }}</option>
              <option :value="OTHER_HOLDER">Other — not a person here…</option>
              <option :value="NOBODY">Nobody — it is in magacin</option>
            </select>
          </label>
          <label v-if="reservePersonId === OTHER_HOLDER">
            <span>What the books say</span>
            <input id="reserve-other" v-model="reserveOther" maxlength="120" placeholder="office Struga, sluzbeno vozilo, initials…" />
          </label>
          <div class="form-actions">
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="reserving = null">Cancel</button>
            <button type="submit" class="button small-btn" :disabled="busy">{{ reservePersonId === OTHER_HOLDER || reservePersonId === NOBODY ? 'Record holder' : 'Confirm reservation' }}</button>
          </div>
        </form>

        <form v-if="returning" class="form inline" novalidate @submit.prevent="confirmReturn">
          <div class="form-title">Return {{ returning.asset_tag }}</div>
          <label><span>Condition</span><input id="return-condition" v-model="returnForm.condition" placeholder="As returned" /></label>
          <label>
            <span>Then it is</span>
            <select id="return-status" v-model="returnForm.status">
              <option v-for="s in RETURN_STATUSES" :key="s.key" :value="s.key">{{ s.label }}</option>
            </select>
          </label>
          <div class="form-actions">
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="returning = null">Cancel</button>
            <button type="submit" class="button small-btn" :disabled="busy">Confirm return</button>
          </div>
        </form>

        <div v-if="!shown.length" class="empty">No assets here.</div>
        <div v-for="a in shown" :key="a.id" class="asset-row" :class="a.status" :data-testid="`asset-${a.asset_tag}`">
          <div class="row-text">
            <strong><span v-if="a.ordinal !== null" class="muted">{{ a.ordinal }}. </span>{{ assetNumbers(a) }}</strong>
            <small class="register-line">{{ registerLine(a) }}</small>
            <small>
              <span class="badge" :class="a.company_id === null ? 'blue' : ''">{{ ownerLabel(a.company_id, companyNames) }}</span>
              {{ assetStatusLabel(a.status) }}
              <template v-if="openAssignment(a)?.issued_at"> · issued {{ openAssignment(a)!.issued_at!.slice(0, 10) }}</template>
              <template v-if="a.serial_number"> · S/N {{ a.serial_number }}</template>
              <template v-if="a.condition"> · {{ a.condition }}</template>
            </small>
          </div>
          <div class="actions">
            <button v-if="canFor(a)('it.assign')" class="button secondary small-btn" type="button" :disabled="busy" @click="editAsset(a)">Edit</button>
            <button v-if="canFor(a)('it.assign')" class="button secondary small-btn danger" type="button" :disabled="busy" @click="removeAsset(a)">Delete</button>
            <button v-for="action in actionsFor(a)" :key="action.key" class="button small-btn" :class="{ secondary: action.key === 'cancel' }" type="button" :disabled="busy" @click="act(a, action)">
              {{ action.label }}
            </button>
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.button.danger { color: #a8332b; border-color: #e6c9c6; }
.page-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 22px; }
.page-sub { margin: 4px 0 0; font-size: 12px; color: var(--muted); max-width: 620px; }
.notice { padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin-bottom: 12px; }
.form { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px 14px; padding: 14px 24px; border-top: 1px solid #edf0eb; background: #fafbf8; }
.form.inline { grid-template-columns: 1fr; max-width: 420px; }
.form label { display: grid; gap: 5px; font-size: 11px; color: var(--muted); }
.form input, .form select { border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; background: #fff; color: var(--ink); }
.form-title { grid-column: 1 / -1; font-size: 12px; font-weight: 600; }
.form-actions { grid-column: 1 / -1; display: flex; gap: 8px; justify-content: flex-end; }
.asset-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; font-size: 11px; color: var(--muted); margin-top: 4px; }
.register-line { display: block; }
.muted { color: var(--muted); font-weight: 400; }
.actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
