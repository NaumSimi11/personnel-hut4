<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { z } from 'zod'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'

/**
 * Request a new hire. Always submits straight to `submitted` — the database
 * trigger (app.gate_hiring_request_transitions) and RLS enforce who may later
 * decide it; this dialog only collects the request itself.
 */
const emit = defineEmits<{ created: [] }>()

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
})
const error = ref<string | null>(null)
const busy = ref(false)

const input = z.object({
  companyId: z.string().uuid('Choose a company.'),
  title: z.string().trim().min(2, 'Enter a job title.').max(120),
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
  form.value = {
    companyId: companies.value[0]?.id ?? '',
    title: '',
    reason: '',
    headcount: 1,
    targetStartDate: '',
    hiringManagerId: '',
  }
  dialog.value?.showModal()
}
defineExpose({ open })

async function submit(): Promise<void> {
  error.value = null
  const parsed = input.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  try {
    const { error: insertErr } = await supabase.from('hiring_requests').insert({
      company_id: parsed.data.companyId,
      title: parsed.data.title,
      reason: parsed.data.reason || null,
      headcount: parsed.data.headcount,
      target_start_date: parsed.data.targetStartDate || null,
      hiring_manager_id: parsed.data.hiringManagerId || null,
      requested_by: auth.personId,
      status: 'submitted',
    })
    if (insertErr) throw new Error(friendly(insertErr.message))
    dialog.value?.close()
    emit('created')
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not create the hiring request.'
  } finally {
    busy.value = false
  }
}

function friendly(message: string): string {
  if (/row-level security/.test(message))
    return 'You do not have permission to request hires for this company.'
  return message
}

onMounted(async () => {
  const [companiesRes, peopleRes] = await Promise.all([
    supabase.from('companies').select('id, name').eq('kind', 'company').order('name'),
    supabase.from('people').select('id, full_name').order('full_name'),
  ])
  companies.value = companiesRes.data ?? []
  people.value = peopleRes.data ?? []
  if (!form.value.companyId && companies.value[0]) form.value.companyId = companies.value[0].id
})
</script>

<template>
  <dialog ref="dialog" class="request-hire" aria-labelledby="request-hire-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Recruitment</div>
      <h2 id="request-hire-title">Request a hire.</h2>
      <p class="hint">
        This starts the request stage. An approver with the right capability decides it next —
        you cannot decide your own request.
      </p>
      <div class="grid">
        <div class="field">
          <label for="rh-company">Company</label>
          <select id="rh-company" v-model="form.companyId">
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
        <div class="field">
          <label for="rh-start">Target start date (optional)</label>
          <input id="rh-start" v-model="form.targetStartDate" type="date" />
        </div>
        <div class="field">
          <label for="rh-manager">Hiring manager (optional)</label>
          <select id="rh-manager" v-model="form.hiringManagerId">
            <option value="">No hiring manager yet</option>
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
          {{ busy ? 'Submitting…' : 'Request hire' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
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
</style>
