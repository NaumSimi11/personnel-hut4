<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { z } from 'zod'
import { cleanJobTitle, jobTitleProblem } from '@/lib/jobTitle'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { deliverNotifications, deliverySentence } from '@/lib/notificationsApi'
import { bandFields, parseSalaryBand } from '@/lib/salaryBand'

/**
 * Request a new hire — or revise one that was sent back (plan 042). A new
 * request submits straight to `submitted`; a revision updates the same row
 * and resubmits it. The database trigger (app.gate_hiring_request_transitions)
 * and RLS enforce who may decide, who may resubmit, and that a submitted
 * request cannot be edited; this dialog only collects the request itself.
 */
export type RevisionTarget = {
  id: string
  company_id: string
  title: string
  reason: string | null
  headcount: number
  target_start_date: string | null
  hiring_manager_id: string | null
  change_reason: string | null
  budget?: unknown
}

const emit = defineEmits<{ created: [notice: string | null]; revised: [notice: string | null] }>()

const auth = useAuthStore()
const dialog = ref<HTMLDialogElement | null>(null)
const companies = ref<{ id: string; name: string }[]>([])
const people = ref<{ id: string; full_name: string }[]>([])
const form = ref({
  companyId: '',
  title: '',
  reason: '',
  headcount: 1,
  targetStartDate: '',
  hiringManagerId: '',
  bandMin: '',
  bandMax: '',
  bandCurrency: 'EUR',
})
const error = ref<string | null>(null)
const busy = ref(false)
const revising = ref<RevisionTarget | null>(null)

const input = z.object({
  companyId: z.string().uuid('Choose a company.'),
  title: z
    .string()
    .max(120)
    .transform(cleanJobTitle)
    .superRefine((value, ctx) => {
      const problem = jobTitleProblem(value)
      if (problem) ctx.addIssue({ code: z.ZodIssueCode.custom, message: problem })
    }),
  reason: z.string().trim().max(2000, 'Keep the reason under 2000 characters.'),
  headcount: z.coerce.number().int().min(1, 'Headcount must be at least 1.'),
  targetStartDate: z.union([
    z.literal(''),
    z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a valid start date.'),
  ]),
  hiringManagerId: z.union([z.literal(''), z.string().uuid()]),
})

function open(): void {
  error.value = null
  revising.value = null
  form.value = {
    companyId: companies.value[0]?.id ?? '',
    title: '',
    reason: '',
    headcount: 1,
    targetStartDate: '',
    hiringManagerId: '',
    ...bandFields(null),
  }
  dialog.value?.showModal()
}

// 0110 (spec 10.4): an approved request. A new start date or hiring manager
// saves as it is; a change to title, reason, headcount or band goes back
// through the approval route.
const amending = ref(false)
function openAmend(target: RevisionTarget): void {
  openRevision(target)
  amending.value = true
}

/** Prefilled with the request that was sent back; saving resubmits it. */
function openRevision(target: RevisionTarget): void {
  error.value = null
  amending.value = false
  revising.value = target
  form.value = {
    companyId: target.company_id,
    title: target.title,
    reason: target.reason ?? '',
    headcount: target.headcount,
    targetStartDate: target.target_start_date ?? '',
    hiringManagerId: target.hiring_manager_id ?? '',
    ...bandFields(target.budget),
  }
  dialog.value?.showModal()
}
defineExpose({ open, openRevision, openAmend })

async function submit(): Promise<void> {
  error.value = null
  const parsed = input.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  const band = parseSalaryBand(form.value.bandMin, form.value.bandMax, form.value.bandCurrency)
  if (band.error) {
    error.value = band.error
    return
  }
  busy.value = true
  try {
    if (revising.value && amending.value) {
      const { data, error: rpcErr } = await supabase.rpc('amend_hiring_request', {
        p_request_id: revising.value.id,
        p: {
          title: parsed.data.title,
          reason: parsed.data.reason || null,
          headcount: parsed.data.headcount,
          target_start_date: parsed.data.targetStartDate || null,
          hiring_manager_id: parsed.data.hiringManagerId || null,
          budget: band.band,
        },
      })
      if (rpcErr) throw new Error(friendly(rpcErr.message))
      dialog.value?.close()
      const again = (data as { reapproval?: boolean } | null)?.reapproval
      emit('revised', again ? `Back in approval — the change needs the route again. ${deliverySentence(await deliverNotifications())}` : 'Saved. No new approval was needed.')
      return
    }
    if (revising.value) {
      const { data, error: updErr } = await supabase
        .from('hiring_requests')
        .update({
          title: parsed.data.title,
          reason: parsed.data.reason || null,
          headcount: parsed.data.headcount,
          target_start_date: parsed.data.targetStartDate || null,
          hiring_manager_id: parsed.data.hiringManagerId || null,
          budget: band.band,
          status: 'submitted',
        })
        .eq('id', revising.value.id)
        .select('id')
        .maybeSingle()
      if (updErr || !data) throw new Error(friendly(updErr?.message ?? 'row-level security'))
      dialog.value?.close()
      emit('revised', deliverySentence(await deliverNotifications()))
      return
    }
    const { data: created, error: insertErr } = await supabase.from('hiring_requests').insert({
      company_id: parsed.data.companyId,
      title: parsed.data.title,
      reason: parsed.data.reason || null,
      headcount: parsed.data.headcount,
      target_start_date: parsed.data.targetStartDate || null,
      hiring_manager_id: parsed.data.hiringManagerId || null,
      budget: band.band,
      requested_by: auth.personId,
      status: 'submitted',
    }).select('id').maybeSingle()
    if (insertErr) throw new Error(friendly(insertErr.message))
    dialog.value?.close()
    emit('created', created ? deliverySentence(await deliverNotifications()) : null)
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not create the hiring request.'
  } finally {
    busy.value = false
  }
}

function friendly(message: string): string {
  if (message.includes('Only the requester')) return 'Only the person who requested this hire can revise and resubmit it.'
  if (message.includes('cannot be edited')) return 'This request is in review and cannot be edited; ask the approver to send it back.'
  if (/row-level security/.test(message))
    return 'You do not have permission to request hires for this company.'
  return message
}

// Only people who could actually own the vacancy in the chosen company — HR and
// above. The list follows the company, because the right names differ per one.
async function loadManagers(companyId: string): Promise<void> {
  if (!companyId) { people.value = []; return }
  const { data, error: err } = await supabase.rpc('hiring_managers', { p_company_id: companyId })
  if (err) {
    console.error('Hiring managers load failed:', err.message)
    people.value = []
    return
  }
  people.value = (data ?? []) as { id: string; full_name: string }[]
  // A manager chosen for another company is no longer a valid answer.
  if (form.value.hiringManagerId && !people.value.some((p) => p.id === form.value.hiringManagerId)) {
    form.value.hiringManagerId = ''
  }
}
watch(() => form.value.companyId, loadManagers)

onMounted(async () => {
  const companiesRes = await supabase.from('companies').select('id, name').is('archived_at', null).order('name')
  companies.value = companiesRes.data ?? []
  if (!form.value.companyId && companies.value[0]) form.value.companyId = companies.value[0].id
  await loadManagers(form.value.companyId)
})
</script>

<template>
  <dialog ref="dialog" class="request-hire" aria-labelledby="request-hire-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Recruitment</div>
      <h2 id="request-hire-title">{{ amending ? 'Change the approved request.' : revising ? 'Revise and resubmit.' : 'Request a hire.' }}</h2>
      <p v-if="!amending && revising?.change_reason" class="change-reason" data-testid="revision-reason">
        <b>Changes requested:</b> {{ revising.change_reason }}
      </p>
      <p class="hint">
        {{ amending
          ? 'A new start date or hiring manager saves straight away. Changing the title, reason, headcount or salary band sends it back for approval.'
          : revising
          ? 'Edit the request below; saving sends it back to the approval queue for another review.'
          : 'This starts the request stage. An approver with the right capability decides it next — you cannot decide your own request.' }}
      </p>
      <div class="grid">
        <div class="field">
          <label for="rh-company">Company</label>
          <select id="rh-company" v-model="form.companyId" :disabled="!!revising">
            <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
          </select>
        </div>
        <div class="field">
          <label for="rh-title">Job title</label>
          <input id="rh-title" v-model="form.title" required maxlength="120" />
        </div>
        <div class="field">
          <label for="rh-headcount">Headcount</label>
          <input id="rh-headcount" v-model="form.headcount" type="number" min="1" required />
        </div>
        <fieldset class="field band">
          <legend>Salary band (optional) — offers outside it also go to Finance and the Director</legend>
          <div class="band-row">
            <input id="rh-band-min" v-model="form.bandMin" inputmode="decimal" placeholder="From" aria-label="Band from" />
            <input id="rh-band-max" v-model="form.bandMax" inputmode="decimal" placeholder="To" aria-label="Band to" />
            <input id="rh-band-currency" v-model="form.bandCurrency" maxlength="3" aria-label="Currency" class="currency" />
          </div>
        </fieldset>
        <div class="field">
          <label for="rh-start">Target start date (optional)</label>
          <input id="rh-start" v-model="form.targetStartDate" type="date" />
        </div>
        <div class="field">
          <label for="rh-manager">Hiring manager (optional)</label>
          <select id="rh-manager" v-model="form.hiringManagerId">
            <option value="">No hiring manager yet</option>
            <option v-if="!people.length" disabled>Nobody here holds HR or recruitment access</option>
            <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
          </select>
        </div>
      </div>
      <div class="field">
        <label for="rh-reason">Reason (optional)</label>
        <textarea id="rh-reason" v-model="form.reason" rows="3" maxlength="2000"></textarea>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy">
          {{ busy ? 'Saving…' : amending ? 'Save changes' : revising ? 'Resubmit request' : 'Request hire' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.band { border: 0; padding: 0; margin: 0; display: grid; gap: 6px; }
.band legend { font-size: 0.85rem; color: var(--muted); padding: 0; }
.band-row { display: flex; gap: 8px; flex-wrap: wrap; }
.band-row input { flex: 1 1 120px; min-width: 0; }
.band-row .currency { flex: 0 0 70px; text-transform: uppercase; }
.request-hire {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(560px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.request-hire::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 11px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.change-reason { margin: 0 0 8px; padding: 10px 12px; border-radius: 9px; background: #e8eef8; color: #3f5f8f; font-size: 12px; line-height: 1.5; }
</style>
