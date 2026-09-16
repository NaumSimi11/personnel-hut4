<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import {
  offerActions,
  offerStatusLabel,
  offerTermsInput,
  termsFromOffer,
  termsToRow,
  type OfferTerms,
  type OfferTermsForm,
} from '@/lib/offers'

/**
 * The offer for one application (plan 018b): explicit terms, then a state
 * machine enforced by advance_offer — draft → in approval → approved (by
 * someone else) → extended → accepted / declined. One live offer per
 * application (unique index in 0003); superseded ones stay as history.
 */

type Offer = {
  id: string
  status: string
  terms: unknown
  created_by: string | null
  approved_by: string | null
  accepted_at: string | null
  extended_at: string | null
  decline_reason: string | null
  created_at: string
  author: { full_name: string } | null
  approver: { full_name: string } | null
}

const props = defineProps<{ applicationId: string; companyId: string; canReview: boolean; stage: string }>()
const emit = defineEmits<{ accepted: [terms: OfferTerms] }>()

const auth = useAuthStore()
const dialogs = useDialogStore()
const offers = ref<Offer[]>([])
const payBases = ref<{ key: string; label: string }[]>([])
const employmentTypes = ref<{ key: string; label: string }[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const busy = ref(false)
const editing = ref(false)
const form = ref<OfferTermsForm>(termsFromOffer(null))

const can = (cap: string) => auth.can(props.companyId, cap)
const live = computed(() => offers.value.find((o) => !['declined', 'withdrawn'].includes(o.status)) ?? null)
const history = computed(() => offers.value.filter((o) => o.id !== live.value?.id))
const canDraft = computed(() => props.canReview && !live.value && ['interview', 'offer'].includes(props.stage))
const isOwnInApproval = computed(
  () => live.value?.status === 'in_approval' && live.value.created_by !== null && live.value.created_by === auth.personId,
)

function actionsFor(o: Offer) {
  return offerActions(o, auth.personId, can)
}

/** Only a complete set of terms renders; a seeded `{}` shows as "no terms yet". */
function terms(o: Offer): OfferTerms | null {
  const t = o.terms as Partial<OfferTerms> | null
  if (!t || typeof t !== 'object') return null
  if (typeof t.salary !== 'number' || typeof t.currency !== 'string' || typeof t.start_date !== 'string') return null
  return t as OfferTerms
}

function labelFor(list: { key: string; label: string }[], key: string): string {
  return list.find((x) => x.key === key)?.label ?? key
}

function badgeClass(status: string): string {
  if (status === 'accepted' || status === 'approved') return 'green'
  if (status === 'in_approval' || status === 'extended') return 'amber'
  return status === 'draft' ? 'blue' : ''
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [offersRes, basesRes, typesRes] = await Promise.all([
    supabase
      .from('offers')
      .select(
        `id, status, terms, created_by, approved_by, accepted_at, extended_at, decline_reason, created_at,
         author:people!offers_created_by_fkey(full_name),
         approver:people!offers_approved_by_fkey(full_name)`,
      )
      .eq('application_id', props.applicationId)
      .order('created_at', { ascending: false }),
    supabase.from('pay_bases').select('key, label').order('sort_order'),
    supabase.from('employment_types').select('key, label').is('archived_at', null).order('sort_order'),
  ])
  if (offersRes.error) {
    error.value = 'Could not load the offer. Check your access and connection.'
    console.error('Offers load failed:', offersRes.error.message)
  }
  offers.value = (offersRes.data ?? []) as Offer[]
  payBases.value = basesRes.data ?? []
  employmentTypes.value = typesRes.data ?? []
  loading.value = false
}

function startEditing(): void {
  form.value = termsFromOffer(live.value?.terms ?? null)
  editing.value = true
  error.value = null
}

async function saveTerms(): Promise<void> {
  error.value = null
  const parsed = offerTermsInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the offer terms.'
    return
  }
  busy.value = true
  const row = termsToRow(parsed.data)
  if (live.value) {
    const { data, error: err } = await supabase
      .from('offers')
      .update({ terms: row })
      .eq('id', live.value.id)
      .select('id')
      .maybeSingle()
    busy.value = false
    if (err || !data) {
      error.value = err ? friendlyRecruitmentError(err.message) : 'Terms can only be edited while the offer is a draft.'
      return
    }
  } else {
    const { error: err } = await supabase.from('offers').insert({
      application_id: props.applicationId,
      company_id: props.companyId, // derived server-side
      terms: row,
      created_by: auth.personId,
    })
    busy.value = false
    if (err) {
      error.value = friendlyRecruitmentError(err.message)
      return
    }
  }
  editing.value = false
  await load()
}

async function advance(o: Offer, to: string): Promise<void> {
  error.value = null
  let reason: string | null = null
  if (to === 'declined') {
    const answer = await dialogs.askReason({
      title: 'Why did the candidate decline?',
      hint: 'The reason stays with the offer in its history.',
      confirmLabel: 'Record decline',
    })
    if (!answer) return
    reason = answer.reason
  } else if (to === 'withdrawn') {
    const answer = await dialogs.askReason({
      title: 'Why is the offer being withdrawn?',
      hint: 'The offer moves to history; a new one can be drafted afterwards.',
      required: false,
      confirmLabel: 'Withdraw offer',
      danger: true,
    })
    if (!answer) return
    reason = answer.reason
  }
  busy.value = true
  const { error: err } = await supabase.rpc('advance_offer', {
    p_offer_id: o.id,
    p_to_status: to,
    p_reason: reason ?? undefined,
  })
  busy.value = false
  if (err) {
    error.value = friendlyRecruitmentError(err.message)
    return
  }
  await load()
  if (to === 'accepted') {
    const t = terms(o)
    if (t) emit('accepted', t)
  }
}

onMounted(load)
defineExpose({ reload: load, liveTerms: () => (live.value ? terms(live.value) : null), liveStatus: () => live.value?.status ?? null })
</script>

<template>
  <div class="card offer-card">
    <div class="card-head">
      <div>
        <h2>Offer</h2>
        <p>Explicit terms, approved by someone other than the author, then extended.</p>
      </div>
      <button v-if="canDraft && !editing" class="button secondary" type="button" @click="startEditing">
        Draft offer
      </button>
      <button
        v-else-if="live?.status === 'draft' && canReview && !editing"
        class="button secondary"
        type="button"
        @click="startEditing"
      >
        Edit terms
      </button>
    </div>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>

    <form v-if="editing" class="terms-form" @submit.prevent="saveTerms">
      <div class="grid">
        <div class="field">
          <label for="offer-salary">Salary</label>
          <input id="offer-salary" v-model="form.salary" type="number" min="0" step="0.01" inputmode="decimal" />
        </div>
        <div class="field">
          <label for="offer-currency">Currency</label>
          <input id="offer-currency" v-model="form.currency" maxlength="3" class="code" />
        </div>
        <div class="field">
          <label for="offer-basis">Pay basis</label>
          <select id="offer-basis" v-model="form.payBasis">
            <option v-for="b in payBases" :key="b.key" :value="b.key">{{ b.label }}</option>
          </select>
        </div>
        <div class="field">
          <label for="offer-start">Start date</label>
          <input id="offer-start" v-model="form.startDate" type="date" />
        </div>
        <div class="field">
          <label for="offer-type">Employment type</label>
          <select id="offer-type" v-model="form.employmentType">
            <option v-for="t in employmentTypes" :key="t.key" :value="t.key">{{ t.label }}</option>
          </select>
        </div>
      </div>
      <div class="field">
        <label for="offer-notes">Notes (internal)</label>
        <textarea id="offer-notes" v-model="form.notes" rows="2" maxlength="1000"></textarea>
      </div>
      <div class="actions">
        <button class="button secondary" type="button" @click="editing = false">Cancel</button>
        <button class="button" type="submit" :disabled="busy">{{ busy ? 'Saving…' : 'Save terms' }}</button>
      </div>
    </form>

    <div v-if="loading" class="empty">Loading offer…</div>
    <div v-else-if="!live && !editing" class="empty">
      <template v-if="['interview', 'offer'].includes(stage)">No offer drafted yet.</template>
      <template v-else-if="stage === 'hired'">Hired — the accepted offer is in the history below.</template>
      <template v-else>An offer can be drafted once the candidate reaches the interview stage.</template>
    </div>
    <div v-else-if="live" class="offer-body">
      <div class="offer-head">
        <div class="row-text">
          <strong v-if="terms(live)">
            {{ terms(live)!.salary.toLocaleString() }} {{ terms(live)!.currency }} · {{ labelFor(payBases, terms(live)!.pay_basis) }}
            · starts {{ terms(live)!.start_date }} · {{ labelFor(employmentTypes, terms(live)!.employment_type) }}
          </strong>
          <small>
            Drafted by {{ live.author?.full_name ?? '—' }}
            <template v-if="live.approver"> · approved by {{ live.approver.full_name }}</template>
            <template v-if="live.extended_at"> · extended {{ new Date(live.extended_at).toLocaleDateString() }}</template>
            <template v-if="live.accepted_at"> · accepted {{ new Date(live.accepted_at).toLocaleDateString() }}</template>
          </small>
          <small v-if="terms(live)?.notes">{{ terms(live)!.notes }}</small>
        </div>
        <span class="badge" :class="badgeClass(live.status)">{{ offerStatusLabel(live.status) }}</span>
      </div>
      <p v-if="isOwnInApproval" class="inline-note">You drafted this offer, so you cannot approve it — someone with offer approval has to.</p>
      <div class="actions left">
        <button
          v-for="a in actionsFor(live)"
          :key="a.to"
          class="button small-btn"
          :class="{ secondary: !['approved', 'accepted'].includes(a.to) }"
          type="button"
          :disabled="busy"
          @click="advance(live, a.to)"
        >
          {{ a.label }}
        </button>
      </div>
    </div>

    <details v-if="history.length" class="history">
      <summary>Previous offers ({{ history.length }})</summary>
      <div v-for="o in history" :key="o.id" class="history-row">
        <span class="badge">{{ offerStatusLabel(o.status) }}</span>
        <small>
          <template v-if="terms(o)">{{ terms(o)!.salary.toLocaleString() }} {{ terms(o)!.currency }} · starts {{ terms(o)!.start_date }}</template>
          <template v-if="o.decline_reason"> · {{ o.decline_reason }}</template>
        </small>
      </div>
    </details>
  </div>
</template>

<style scoped>
.terms-form { padding: 16px 24px 18px; border-top: 1px solid var(--line); background: #fafbf9; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
.code { text-transform: uppercase; }
.field textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 9px 11px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
.actions { display: flex; gap: 9px; justify-content: flex-end; }
.actions.left { justify-content: flex-start; flex-wrap: wrap; margin-top: 12px; }
.offer-body { padding: 16px 24px 18px; border-top: 1px solid #edf0eb; }
.offer-head { display: flex; align-items: center; gap: 13px; flex-wrap: wrap; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.inline-note { margin: 10px 0 0; font-size: 11px; color: var(--amber); }
.small-btn { font-size: 11px; padding: 7px 11px; }
.history { border-top: 1px solid var(--line); }
.history summary { padding: 12px 24px; font-size: 11px; color: var(--muted); cursor: pointer; }
.history-row { display: flex; align-items: center; gap: 10px; padding: 8px 24px 12px; font-size: 11px; }
</style>
