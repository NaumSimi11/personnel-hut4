<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import {
  assetStatusLabel,
  equipmentRequestInput,
  itRequestStatusLabel,
  returnActions,
  returnRequestInput,
  returnStatusLine,
  type EquipmentReturn,
  type ReturnAction,
} from '@/lib/equipment'
import { useDialogStore } from '@/stores/dialogs'
import SignaturePad from '@/components/SignaturePad.vue'
import { capacityFor, returnStatements, type SignatureInput } from '@shared/signature'

/**
 * What one person holds and what IT is doing for them (plan 029): open
 * assignments (reserved or issued) and IT requests that are not closed.
 * Read-only; the viewer is the person or holds it.view in a company they
 * have employment with. RLS on both tables is the gate.
 */

type Company = { id: string; name: string }
const props = withDefaults(defineProps<{ personId: string; companies: Company[]; title?: string }>(), { title: 'Equipment' })

type Held = {
  id: string
  asset_id: string
  reserved_at: string | null
  issued_at: string | null
  returned_at: string | null
  asset: { asset_tag: string; type_key: string; model: string | null; status: string; company_id: string } | null
}
type Request = { id: string; title: string; status: string; company_id: string; requested_systems: unknown; blocked_reason: string | null }
type ReturnRow = EquipmentReturn & {
  asset_id: string
  company_id: string
  asset: { asset_tag: string; model: string | null } | null
  hr: { full_name: string } | null
}
type HrPerson = { id: string; full_name: string }

const auth = useAuthStore()
const visible = computed(
  () => auth.isAdmin || auth.personId === props.personId || props.companies.some((c) => auth.can(c.id, 'it.view')),
)

const loading = ref(true)
const error = ref<string | null>(null)
const held = ref<Held[]>([])
const requests = ref<Request[]>([])
const types = ref<Record<string, string>>({})
const returns = ref<ReturnRow[]>([])
const hrPeople = ref<HrPerson[]>([])
const dialogs = useDialogStore()
const busy = ref(false)
const notice = ref<string | null>(null)

// Only the person themselves asks for equipment or hands it back; a colleague
// looking at this card is reading, not acting on their behalf.
const isMe = computed(() => auth.personId === props.personId)

const asking = ref(false)
const askForm = ref({ companyId: '', title: '', note: '' })
const returning = ref<Held | null>(null)
const returnForm = ref({ hrPersonId: '', reason: '', condition: '' })
// The form is filled first, then signed: you should know what you are putting
// your name to before the pad appears.
const signingReturn = ref(false)
// One dialog serves both signatures; which one is decided by whether an accept
// is in flight, so the pad, the statement and the capacity stay in step.
const signing = computed(() => signingReturn.value || acceptingReturn.value !== null)
const signingTitle = computed(() =>
  acceptingReturn.value
    ? `Accept ${acceptingReturn.value.asset?.asset_tag ?? 'this asset'} back`
    : `Sign the return of ${returning.value?.asset?.asset_tag ?? 'this asset'}`,
)
function closeSigning(): void {
  signingReturn.value = false
  acceptingReturn.value = null
}
const acceptingReturn = ref<ReturnRow | null>(null)

const companyOfReturn = computed(() =>
  companyName(returning.value?.asset?.company_id ?? acceptingReturn.value?.company_id ?? '') || 'the company',
)
const statements = computed(() => returnStatements(companyOfReturn.value))

/** A return in flight for an asset, so its row can say so instead of offering Return again. */
const openReturnFor = (assetId: string) =>
  returns.value.find((r) => r.asset_id === assetId && r.status === 'awaiting_hr') ?? null
const mine = computed(() => returns.value.filter((r) => r.person_id === auth.personId))
const forMe = computed(() => returns.value.filter((r) => r.hr_person_id === auth.personId && r.status === 'awaiting_hr'))

async function run(label: string, fn: () => Promise<{ error: { message: string } | null }>): Promise<boolean> {
  busy.value = true
  error.value = null
  const { error: err } = await fn()
  busy.value = false
  if (err) {
    error.value = err.message
    console.error(`${label} failed:`, err.message)
    return false
  }
  await load()
  return true
}

function openAsk(): void {
  askForm.value = { companyId: props.companies[0]?.id ?? '', title: '', note: '' }
  notice.value = null
  asking.value = true
}

async function submitAsk(): Promise<void> {
  const parsed = equipmentRequestInput.safeParse(askForm.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  const ok = await run('Request equipment', async () =>
    await supabase.rpc('request_equipment', {
      p_company_id: parsed.data.companyId,
      p_title: parsed.data.title,
      p_note: parsed.data.note || undefined,
    }),
  )
  if (ok) {
    asking.value = false
    notice.value = 'Asked. IT will see it in their queue.'
  }
}

async function openReturn(h: Held): Promise<void> {
  notice.value = null
  returning.value = h
  returnForm.value = { hrPersonId: '', reason: '', condition: '' }
  const companyId = h.asset?.company_id
  if (!companyId) return
  const { data } = await supabase.rpc('hr_people', { p_company_id: companyId })
  // Never offer yourself: you cannot hand equipment back to yourself.
  hrPeople.value = ((data ?? []) as HrPerson[]).filter((h) => h.id !== auth.personId)
  returnForm.value.hrPersonId = hrPeople.value[0]?.id ?? ''
}

function reviewReturn(): void {
  const parsed = returnRequestInput.safeParse(returnForm.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  error.value = null
  signingReturn.value = true
}

async function signAndSend(sig: SignatureInput): Promise<void> {
  if (!returning.value) return
  const parsed = returnRequestInput.safeParse(returnForm.value)
  if (!parsed.success) return
  const ok = await run('Start return', async () =>
    await supabase.rpc('start_equipment_return', {
      p_asset_id: returning.value!.asset_id,
      p_hr_person_id: parsed.data.hrPersonId,
      p_sign_name: sig.name,
      p_sign_method: sig.method,
      p_sign_image: sig.image ?? undefined,
      p_reason: parsed.data.reason || undefined,
      p_condition: parsed.data.condition || undefined,
    }),
  )
  if (ok) {
    returning.value = null
    signingReturn.value = false
    notice.value = 'Signed and sent. It is not returned until HR signs the same form.'
  }
}

async function signAndAccept(sig: SignatureInput): Promise<void> {
  const r = acceptingReturn.value
  if (!r) return
  const ok = await run('Accept return', async () =>
    await supabase.rpc('accept_equipment_return', {
      p_return_id: r.id,
      p_sign_name: sig.name,
      p_sign_method: sig.method,
      p_sign_image: sig.image ?? undefined,
    }),
  )
  if (ok) {
    acceptingReturn.value = null
    notice.value = `${r.asset?.asset_tag ?? 'The asset'} is back in magacin. The form carries both names.`
  }
}

async function actOnReturn(r: ReturnRow, action: ReturnAction): Promise<void> {
  if (action.key === 'accept') {
    // HR signs the same form; accepting without a name on it would leave the
    // person's signature facing nothing.
    acceptingReturn.value = r
    return
  }
  if (action.key === 'decline') {
    const answer = await dialogs.askReason({
      title: 'Not accepting this return?',
      hint: 'The person keeps the equipment. Say what they should do next.',
      confirmLabel: 'Send it back to them',
    })
    if (!answer) return
    await run('Decline return', async () => await supabase.rpc('decline_equipment_return', { p_return_id: r.id, p_reason: answer.reason }))
    return
  }
  const sure = await dialogs.confirmAction({
    title: 'Cancel this return?',
    hint: 'You keep the equipment and HR stops seeing the request.',
    confirmLabel: 'Cancel the return',
    cancelLabel: 'Keep it pending',
  })
  if (sure) await run('Cancel return', async () => await supabase.rpc('cancel_equipment_return', { p_return_id: r.id }))
}

const companyName = (id: string) => props.companies.find((c) => c.id === id)?.name ?? ''
const systemsOf = (r: Request) => (Array.isArray(r.requested_systems) ? r.requested_systems.filter((s): s is string => typeof s === 'string') : [])

async function load(): Promise<void> {
  if (!visible.value) {
    loading.value = false
    return
  }
  loading.value = true
  error.value = null
  const [heldRes, reqRes, typeRes, retRes] = await Promise.all([
    supabase
      .from('asset_assignments')
      .select('id, asset_id, reserved_at, issued_at, returned_at, asset:assets(asset_tag, type_key, model, status, company_id)')
      .eq('person_id', props.personId)
      .is('returned_at', null),
    supabase
      .from('it_requests')
      .select('id, title, status, company_id, requested_systems, blocked_reason')
      .eq('person_id', props.personId)
      .not('status', 'in', '("done","cancelled")'),
    supabase.from('asset_types').select('key, label'),
    // Returns this person started, and any waiting on them as HR.
    supabase
      .from('equipment_returns')
      .select('id, asset_id, company_id, person_id, hr_person_id, status, decline_reason, signed_by_person_at, signed_by_hr_at, asset:assets(asset_tag, model), hr:people!equipment_returns_hr_person_id_fkey(full_name)')
      .or(`person_id.eq.${props.personId},hr_person_id.eq.${auth.personId ?? props.personId}`)
      .order('created_at', { ascending: false }),
  ])
  loading.value = false
  if (heldRes.error || reqRes.error) {
    error.value = 'Could not load equipment.'
    console.error('Person equipment load failed:', heldRes.error?.message ?? reqRes.error?.message)
    return
  }
  held.value = (heldRes.data ?? []) as unknown as Held[]
  requests.value = (reqRes.data ?? []) as Request[]
  types.value = Object.fromEntries((typeRes.data ?? []).map((t) => [t.key, t.label]))
  returns.value = (retRes.data ?? []) as unknown as ReturnRow[]
}

onMounted(load)
watch(() => `${props.personId}|${props.companies.map((c) => c.id).join(',')}`, () => load())
</script>

<template>
  <div v-if="visible" class="card">
    <div class="card-head">
      <div>
        <h2>{{ title }}</h2>
        <p>Equipment on hand and open IT work.</p>
      </div>
      <button v-if="isMe" class="button small-btn" type="button" :disabled="busy" @click="openAsk">Request equipment</button>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="error" class="error" role="alert">{{ error }}</div>
      <div v-for="h in held" :key="h.id" class="equipment-row">
        <div class="row-text">
          <strong>{{ h.asset?.asset_tag }} <span class="muted">· {{ types[h.asset?.type_key ?? ''] ?? h.asset?.type_key }}<template v-if="h.asset?.model"> · {{ h.asset.model }}</template></span></strong>
          <small>
            {{ h.issued_at ? `issued ${h.issued_at.slice(0, 10)}` : `reserved ${h.reserved_at?.slice(0, 10) ?? ''}` }}
            <template v-if="h.asset"> · {{ assetStatusLabel(h.asset.status) }}</template>
            <template v-if="h.asset && companies.length > 1"> · {{ companyName(h.asset.company_id) }}</template>
          </small>
          <small v-if="openReturnFor(h.asset_id)" class="pending">
            Return sent to {{ openReturnFor(h.asset_id)?.hr?.full_name ?? 'HR' }} — waiting for them to accept it.
          </small>
        </div>
        <button
          v-if="isMe && h.issued_at && !openReturnFor(h.asset_id)"
          class="button secondary small-btn"
          type="button"
          :disabled="busy"
          @click="openReturn(h)"
        >Return</button>
      </div>
      <form v-if="asking" class="inline-form" novalidate @submit.prevent="submitAsk">
        <div class="form-title">What do you need?</div>
        <label v-if="companies.length > 1">
          <span>Company</span>
          <select v-model="askForm.companyId">
            <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
          </select>
        </label>
        <label><span>Equipment</span><input v-model="askForm.title" maxlength="120" placeholder="A second monitor" /></label>
        <label><span>Why, or anything useful</span><input v-model="askForm.note" maxlength="500" /></label>
        <div class="form-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="asking = false">Cancel</button>
          <button type="submit" class="button small-btn" :disabled="busy">Send to IT</button>
        </div>
      </form>

      <form v-if="returning" class="inline-form" novalidate @submit.prevent="reviewReturn">
        <div class="form-title">Returning {{ returning.asset?.asset_tag }}</div>
        <label>
          <span>Send to</span>
          <select v-model="returnForm.hrPersonId">
            <option v-for="h in hrPeople" :key="h.id" :value="h.id">{{ h.full_name }}</option>
          </select>
        </label>
        <div v-if="!hrPeople.length" class="empty">Nobody in this company holds HR capabilities yet.</div>
        <label><span>Condition</span><input v-model="returnForm.condition" maxlength="120" placeholder="As issued" /></label>
        <label><span>Why you are returning it</span><input v-model="returnForm.reason" maxlength="500" /></label>
        <p class="inline-note">
          It stays yours until HR signs the same form.
        </p>
        <div class="form-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="returning = null">Cancel</button>
          <button type="submit" class="button small-btn" :disabled="busy || !hrPeople.length">Review and sign</button>
        </div>
      </form>

      <div v-for="r in forMe" :key="r.id" class="equipment-row awaiting">
        <div class="row-text">
          <strong>{{ r.asset?.asset_tag }} — returned to you</strong>
          <small>{{ r.asset?.model }} · signed {{ r.signed_by_person_at?.slice(0, 10) }}</small>
        </div>
        <div class="row-actions">
          <button
            v-for="a in returnActions(r, auth.personId)"
            :key="a.key"
            class="button small-btn"
            :class="{ secondary: a.key !== 'accept' }"
            type="button"
            :disabled="busy"
            @click="actOnReturn(r, a)"
          >{{ a.label }}</button>
        </div>
      </div>

      <div v-for="r in mine.filter((x) => x.status !== 'awaiting_hr')" :key="r.id" class="equipment-row settled">
        <div class="row-text">
          <strong>{{ r.asset?.asset_tag }}</strong>
          <small>{{ returnStatusLine(r, r.hr?.full_name ?? 'HR') }}</small>
        </div>
      </div>

      <p v-if="notice" class="inline-note">{{ notice }}</p>

      <!-- Signing belongs in the middle of the screen, not folded into a row
           halfway down a card: you are putting your name to something, and the
           statement has to be the only thing in front of you. -->
      <dialog v-if="signing" class="sign-dialog" open @click.self="closeSigning">
        <div class="sign-card">
          <div class="sign-head">
            <strong>{{ signingTitle }}</strong>
            <button class="button secondary small-btn" type="button" :disabled="busy" @click="closeSigning">Close</button>
          </div>
          <SignaturePad
            :statement="acceptingReturn ? statements.hr : statements.person"
            :capacity="capacityFor(acceptingReturn ? 'hr' : 'person', companyOfReturn)"
            :suggested-name="auth.personName ?? ''"
            :busy="busy"
            @sign="acceptingReturn ? signAndAccept($event) : signAndSend($event)"
          >
            <template #cancel>
              <button type="button" class="button secondary small-btn" :disabled="busy" @click="closeSigning">Cancel</button>
            </template>
          </SignaturePad>
        </div>
      </dialog>

      <div v-for="r in requests" :key="r.id" class="equipment-row it">
        <div class="row-text">
          <strong>{{ r.title }}</strong>
          <small>
            IT request · {{ itRequestStatusLabel(r.status) }}
            <template v-if="systemsOf(r).length"> · {{ systemsOf(r).join(', ') }}</template>
            <template v-if="r.blocked_reason"> · {{ r.blocked_reason }}</template>
          </small>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.sign-dialog { position: fixed; inset: 0; width: 100%; height: 100%; max-width: none; max-height: none; border: 0; padding: 20px; background: rgba(20, 28, 20, 0.35); display: grid; place-items: center; z-index: 60; }
.sign-card { background: #fff; border-radius: 14px; padding: 22px; width: min(560px, 100%); max-height: 90vh; overflow: auto; box-shadow: 0 18px 50px rgba(20, 28, 20, 0.18); display: grid; gap: 14px; }
.sign-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.sign-head strong { font-size: 14px; font-weight: 650; }
.inline-form { display: grid; gap: 10px; padding: 15px 24px; border-top: 1px solid #edf0eb; background: #f7f9f5; }
.inline-form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.inline-form input, .inline-form select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 8px; background: #fff; }
.form-title { font-size: 12px; font-weight: 600; color: var(--ink); }
.form-actions { display: flex; gap: 8px; justify-content: flex-end; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.equipment-row.awaiting { background: #fbf9ef; }
.equipment-row.settled { opacity: 0.75; }
.pending { color: #8a6d1f !important; }
.equipment-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.muted { font-weight: 400; color: var(--muted); }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
</style>
