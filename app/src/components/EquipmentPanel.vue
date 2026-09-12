<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import {
  RETURN_STATUSES,
  assetInput,
  assetStatusLabel,
  assignmentActions,
  itRequestActions,
  itRequestInput,
  itRequestStatusLabel,
  parseSystems,
  type AssignmentAction,
  type ItRequestAction,
} from '@/lib/equipment'

/**
 * A company's equipment (plan 029): the asset register with reserve / issue
 * / return, and IT requests worked to done. Reading needs it.view; the
 * register is edited by it.assign holders (RLS), everything else goes
 * through the functions of migration 0022.
 */

const props = defineProps<{ companyId: string }>()

type Assignment = {
  id: string
  person_id: string
  reserved_at: string | null
  issued_at: string | null
  returned_at: string | null
  person: { full_name: string } | null
}
type Asset = {
  id: string
  asset_tag: string
  type_key: string
  model: string | null
  serial_number: string | null
  condition: string | null
  status: string
  location_id: string | null
  note: string | null
  asset_assignments: Assignment[]
}
type ItRequest = {
  id: string
  person_id: string
  title: string
  requested_systems: unknown
  due_at: string | null
  status: string
  blocked_reason: string | null
  assignee_id: string | null
  person: { full_name: string } | null
  assignee: { full_name: string } | null
}
type Person = { id: string; full_name: string }

const auth = useAuthStore()
const can = (cap: string) => auth.can(props.companyId, cap)
const canAssign = computed(() => can('it.assign'))

const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const assets = ref<Asset[]>([])
const requests = ref<ItRequest[]>([])
const people = ref<Person[]>([])
const types = ref<{ key: string; label: string }[]>([])
const locations = ref<{ id: string; name: string }[]>([])

const addingAsset = ref(false)
const assetForm = ref({ assetTag: '', typeKey: '', model: '', serialNumber: '', locationId: '', note: '' })
const reserving = ref<Asset | null>(null)
const reservePersonId = ref('')
const returning = ref<Asset | null>(null)
const returnForm = ref({ condition: '', status: 'available' })
const addingRequest = ref(false)
const requestForm = ref({ personId: '', title: '', systems: '', dueDate: '' })

const typeLabel = (key: string) => types.value.find((t) => t.key === key)?.label ?? key
const locationName = (id: string | null) => locations.value.find((l) => l.id === id)?.name ?? ''
const openAssignment = (a: Asset) => a.asset_assignments.find((x) => x.returned_at === null) ?? null
const actionsFor = (a: Asset): AssignmentAction[] => assignmentActions(a, openAssignment(a), can)
const requestActions = (r: ItRequest): ItRequestAction[] => itRequestActions(r.status, can)
const systemsOf = (r: ItRequest) => (Array.isArray(r.requested_systems) ? r.requested_systems.filter((s): s is string => typeof s === 'string') : [])

const sortedAssets = computed(() => [...assets.value].sort((a, b) => a.asset_tag.localeCompare(b.asset_tag)))
const openRequests = computed(() => requests.value.filter((r) => r.status !== 'done' && r.status !== 'cancelled'))
const closedRequests = computed(() => requests.value.filter((r) => r.status === 'done' || r.status === 'cancelled'))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [assetRes, reqRes, peopleRes, typeRes, locRes] = await Promise.all([
    supabase
      .from('assets')
      .select('*, asset_assignments(id, person_id, reserved_at, issued_at, returned_at, person:people!asset_assignments_person_id_fkey(full_name))')
      .eq('company_id', props.companyId),
    supabase
      .from('it_requests')
      .select('*, person:people!it_requests_person_id_fkey(full_name), assignee:people!it_requests_assignee_id_fkey(full_name)')
      .eq('company_id', props.companyId)
      .order('created_at', { ascending: false }),
    supabase
      .from('employment_periods')
      .select('person:people!employment_periods_person_id_fkey(id, full_name)')
      .eq('company_id', props.companyId)
      .neq('status', 'former'),
    supabase.from('asset_types').select('key, label').is('archived_at', null),
    supabase
      .from('locations')
      .select('id, name')
      .or(`company_id.eq.${props.companyId},company_id.is.null`)
      .is('archived_at', null)
      .order('name'),
  ])
  loading.value = false
  if (assetRes.error || reqRes.error) {
    error.value = 'Could not load equipment.'
    console.error('Equipment load failed:', assetRes.error?.message ?? reqRes.error?.message)
    return
  }
  assets.value = (assetRes.data ?? []) as unknown as Asset[]
  requests.value = (reqRes.data ?? []) as unknown as ItRequest[]
  const seen = new Map<string, Person>()
  for (const row of peopleRes.data ?? []) {
    const p = row.person as unknown as Person | null
    if (p && !seen.has(p.id)) seen.set(p.id, p)
  }
  people.value = [...seen.values()].sort((a, b) => a.full_name.localeCompare(b.full_name))
  types.value = typeRes.data ?? []
  locations.value = locRes.data ?? []
}

function friendly(message: string): string {
  if (/row-level security|it\.assign/.test(message)) return 'You need it.assign in this company.'
  if (/it\.complete/.test(message)) return 'You need it.complete (or it.assign) in this company.'
  if (/assets_company_id_asset_tag_key/.test(message)) return 'An asset with this tag already exists in this company.'
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
  assetForm.value = { assetTag: '', typeKey: types.value[0]?.key ?? '', model: '', serialNumber: '', locationId: '', note: '' }
  error.value = null
  notice.value = null
  addingAsset.value = true
}

async function saveAsset(): Promise<void> {
  const parsed = assetInput.safeParse(assetForm.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  const ok = await run('Asset insert', async () => {
    const { data, error: err } = await supabase
      .from('assets')
      .insert({
        company_id: props.companyId,
        asset_tag: parsed.data.assetTag,
        type_key: parsed.data.typeKey,
        model: parsed.data.model || null,
        serial_number: parsed.data.serialNumber || null,
        location_id: parsed.data.locationId || null,
        note: parsed.data.note || null,
      })
      .select('id')
      .maybeSingle()
    return { error: err ?? (data ? null : { message: 'row-level security' }) }
  })
  if (ok) addingAsset.value = false
}

function act(asset: Asset, action: AssignmentAction): void {
  error.value = null
  notice.value = null
  if (action.key === 'reserve') {
    reserving.value = asset
    reservePersonId.value = people.value[0]?.id ?? ''
    return
  }
  if (action.key === 'return') {
    returning.value = asset
    returnForm.value = { condition: '', status: 'available' }
    return
  }
  const open = openAssignment(asset)
  if (!open) return
  if (action.key === 'issue') void run('Issue', () => supabase.rpc('issue_asset', { p_assignment_id: open.id }))
  if (action.key === 'cancel') void run('Cancel reservation', () => supabase.rpc('cancel_reservation', { p_assignment_id: open.id }))
}

async function confirmReserve(): Promise<void> {
  if (!reserving.value || !reservePersonId.value) {
    error.value = 'Choose who it is for.'
    return
  }
  const asset = reserving.value
  const ok = await run('Reserve', () => supabase.rpc('reserve_asset', { p_asset_id: asset.id, p_person_id: reservePersonId.value }))
  if (ok) reserving.value = null
}

async function confirmReturn(): Promise<void> {
  if (!returning.value) return
  const open = openAssignment(returning.value)
  if (!open) return
  const ok = await run('Return', () =>
    supabase.rpc('return_asset', {
      p_assignment_id: open.id,
      p_condition: returnForm.value.condition || undefined,
      p_status: returnForm.value.status,
    }),
  )
  if (ok) returning.value = null
}

function startRequest(): void {
  requestForm.value = { personId: people.value[0]?.id ?? '', title: '', systems: '', dueDate: '' }
  error.value = null
  notice.value = null
  addingRequest.value = true
}

async function createRequest(): Promise<void> {
  const parsed = itRequestInput.safeParse(requestForm.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  const ok = await run('IT request insert', async () => {
    const { data, error: err } = await supabase
      .from('it_requests')
      .insert({
        company_id: props.companyId,
        person_id: parsed.data.personId,
        kind: 'manual',
        title: parsed.data.title,
        requested_systems: parseSystems(parsed.data.systems),
        due_at: parsed.data.dueDate ? `${parsed.data.dueDate}T17:00:00Z` : null,
      })
      .select('id')
      .maybeSingle()
    return { error: err ?? (data ? null : { message: 'row-level security' }) }
  })
  if (ok) addingRequest.value = false
}

async function advance(request: ItRequest, action: ItRequestAction): Promise<void> {
  let reason: string | null = null
  if (action.to === 'blocked') {
    reason = window.prompt('What blocks it?')
    if (!reason) return
  }
  if (action.to === 'cancelled' && !window.confirm('Cancel this request?')) return
  await run('IT request transition', () =>
    supabase.rpc('advance_it_request', { p_request_id: request.id, p_status: action.to, p_blocked_reason: reason ?? undefined }),
  )
}

onMounted(load)
watch(() => props.companyId, load)
</script>

<template>
  <div class="stack">
    <div v-if="notice" class="notice" role="status">{{ notice }}</div>
    <div v-if="error" class="error" role="alert">{{ error }}</div>
    <div class="card">
      <div class="card-head">
        <div>
          <h2>Assets</h2>
          <p>Laptops, phones, licences: reserved for a person, issued, returned. Status follows the handovers.</p>
        </div>
        <button v-if="canAssign && !addingAsset" class="button small-btn" type="button" @click="startAsset">Add asset</button>
      </div>
      <div v-if="loading" class="empty">Loading…</div>
      <template v-else>
        <form v-if="addingAsset" class="form" novalidate @submit.prevent="saveAsset">
          <label><span>Asset tag</span><input id="asset-tag" v-model="assetForm.assetTag" maxlength="60" /></label>
          <label>
            <span>Type</span>
            <select id="asset-type" v-model="assetForm.typeKey">
              <option v-for="t in types" :key="t.key" :value="t.key">{{ t.label }}</option>
            </select>
          </label>
          <label><span>Model</span><input id="asset-model" v-model="assetForm.model" maxlength="120" /></label>
          <label><span>Serial number</span><input id="asset-serial" v-model="assetForm.serialNumber" maxlength="120" /></label>
          <label>
            <span>Location</span>
            <select id="asset-location" v-model="assetForm.locationId">
              <option value="">None</option>
              <option v-for="l in locations" :key="l.id" :value="l.id">{{ l.name }}</option>
            </select>
          </label>
          <label><span>Note</span><input id="asset-note" v-model="assetForm.note" /></label>
          <div class="form-actions">
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="addingAsset = false">Cancel</button>
            <button type="submit" class="button small-btn" :disabled="busy">Save asset</button>
          </div>
        </form>

        <form v-if="reserving" class="form inline" novalidate @submit.prevent="confirmReserve">
          <div class="form-title">Reserve {{ reserving.asset_tag }} for</div>
          <label>
            <span>Person</span>
            <select id="reserve-person" v-model="reservePersonId">
              <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
            </select>
          </label>
          <div class="form-actions">
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="reserving = null">Cancel</button>
            <button type="submit" class="button small-btn" :disabled="busy">Confirm reservation</button>
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

        <div v-if="!sortedAssets.length" class="empty">No assets registered.</div>
        <div v-for="a in sortedAssets" :key="a.id" class="asset-row" :class="a.status">
          <div class="row-text">
            <strong>{{ a.asset_tag }} <span class="muted">· {{ typeLabel(a.type_key) }}<template v-if="a.model"> · {{ a.model }}</template></span></strong>
            <small>
              {{ assetStatusLabel(a.status) }}
              <template v-if="openAssignment(a)"> · {{ openAssignment(a)!.person?.full_name ?? 'someone' }}<template v-if="openAssignment(a)!.issued_at"> (issued {{ openAssignment(a)!.issued_at!.slice(0, 10) }})</template></template>
              <template v-if="a.serial_number"> · S/N {{ a.serial_number }}</template>
              <template v-if="a.location_id"> · {{ locationName(a.location_id) }}</template>
              <template v-if="a.condition"> · {{ a.condition }}</template>
            </small>
          </div>
          <div class="actions">
            <button
              v-for="action in actionsFor(a)"
              :key="action.key"
              class="button small-btn"
              :class="{ secondary: action.key === 'cancel' }"
              type="button"
              :disabled="busy"
              @click="act(a, action)"
            >
              {{ action.label }}
            </button>
          </div>
        </div>
      </template>
    </div>

    <div class="card">
      <div class="card-head">
        <div>
          <h2>IT requests</h2>
          <p>Accounts, access and setup work for a person — picked up, blocked with a reason, done.</p>
        </div>
        <button v-if="canAssign && !addingRequest" class="button small-btn" type="button" @click="startRequest">New request</button>
      </div>
      <div v-if="loading" class="empty">Loading…</div>
      <template v-else>
        <form v-if="addingRequest" class="form" novalidate @submit.prevent="createRequest">
          <label>
            <span>For</span>
            <select id="it-person" v-model="requestForm.personId">
              <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
            </select>
          </label>
          <label><span>What is needed</span><input id="it-title" v-model="requestForm.title" maxlength="160" /></label>
          <label><span>Systems (comma-separated)</span><input id="it-systems" v-model="requestForm.systems" placeholder="email, vpn, erp" /></label>
          <label><span>Due</span><input id="it-due" v-model="requestForm.dueDate" type="date" /></label>
          <div class="form-actions">
            <button type="button" class="button secondary small-btn" :disabled="busy" @click="addingRequest = false">Cancel</button>
            <button type="submit" class="button small-btn" :disabled="busy">Create request</button>
          </div>
        </form>
        <div v-if="!requests.length" class="empty">No IT requests.</div>
        <div v-for="r in [...openRequests, ...closedRequests]" :key="r.id" class="request-row" :class="r.status">
          <div class="row-text">
            <strong>{{ r.title }} <span class="muted">· {{ r.person?.full_name ?? '—' }}</span></strong>
            <small>
              {{ itRequestStatusLabel(r.status) }}
              <template v-if="r.assignee"> · {{ r.assignee.full_name }}</template>
              <template v-if="systemsOf(r).length"> · {{ systemsOf(r).join(', ') }}</template>
              <template v-if="r.due_at"> · due {{ r.due_at.slice(0, 10) }}</template>
              <template v-if="r.blocked_reason"> · {{ r.blocked_reason }}</template>
            </small>
          </div>
          <div class="actions">
            <button
              v-for="action in requestActions(r)"
              :key="action.to"
              class="button small-btn"
              :class="{ secondary: action.to !== 'done' && action.to !== 'in_progress' }"
              type="button"
              :disabled="busy"
              @click="advance(r, action)"
            >
              {{ action.label }}
            </button>
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.stack { display: grid; gap: 22px; }
.asset-row, .request-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.asset-row.retired, .asset-row.lost, .request-row.done, .request-row.cancelled { opacity: 0.6; }
.request-row.blocked { background: #fbf7ea; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.muted { font-weight: 400; color: var(--muted); }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.form { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 14px; padding: 16px 24px; background: #fafbf8; border-top: 1px solid var(--line); }
.form.inline { background: #fbf7ea; }
.form-title { grid-column: 1 / -1; font-size: 12px; font-weight: 600; }
.form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.form .form-actions { grid-column: 1 / -1; display: flex; justify-content: flex-end; gap: 8px; }
.form input, .form select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
.notice { margin: 0; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.error { margin: 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
@media (max-width: 560px) { .form { grid-template-columns: 1fr; } }
</style>
