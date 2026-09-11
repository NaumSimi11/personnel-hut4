<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { z } from 'zod'
import { supabase } from '@/lib/supabase'

/**
 * Confirms a hire through the atomic `confirm_hire` RPC (migration 0009):
 * attaches-by-email or creates the person, opens the employment period, and
 * assigns the standard onboarding plan — all in one call. Retrying an
 * already-confirmed application is safe and returns the same result.
 *
 * The per-invocation target (which application, prefilled candidate name and
 * job title) is passed as an argument to `open()` rather than as a prop —
 * same pattern as InviteAccessDialog.openReset — since this dialog is opened
 * from a per-row action and a prop would not be updated in time for a
 * synchronous read inside `open()`.
 */
const emit = defineEmits<{ hired: [] }>()

type Target = { applicationId: string; candidateName: string; jobTitle: string }

const dialog = ref<HTMLDialogElement | null>(null)
const target = ref<Target | null>(null)
const people = ref<{ id: string; full_name: string }[]>([])
const form = ref({ fullName: '', jobTitle: '', startDate: '', managerId: '' })
const error = ref<string | null>(null)
const busy = ref(false)
const result = ref<{ personId: string } | null>(null)

function open(t: Target): void {
  target.value = t
  error.value = null
  result.value = null
  form.value = {
    fullName: t.candidateName,
    jobTitle: t.jobTitle,
    startDate: new Date().toISOString().slice(0, 10),
    managerId: '',
  }
  dialog.value?.showModal()
}
defineExpose({ open })

const input = z.object({
  fullName: z.string().trim().min(2, "Enter the new employee's full name.").max(120),
  jobTitle: z.string().trim().min(2, 'Enter the position title.').max(120),
  startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a start date.'),
  managerId: z.union([z.literal(''), z.string().uuid()]),
})

async function submit(): Promise<void> {
  if (!target.value) return
  error.value = null
  const parsed = input.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  try {
    const { data, error: rpcErr } = await supabase.rpc('confirm_hire', {
      p_application_id: target.value.applicationId,
      p_full_name: parsed.data.fullName,
      p_job_title: parsed.data.jobTitle,
      p_start_date: parsed.data.startDate,
      p_manager_id: parsed.data.managerId || undefined,
    })
    if (rpcErr) throw new Error(friendly(rpcErr.message))
    const payload = data as { person_id: string }
    result.value = { personId: payload.person_id }
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not confirm the hire.'
  } finally {
    busy.value = false
  }
}

function friendly(message: string): string {
  if (message.includes('employment.edit'))
    return 'Confirming hires needs employment.edit in this company.'
  return message
}

function done(): void {
  dialog.value?.close()
  emit('hired')
}

onMounted(async () => {
  const { data } = await supabase.from('people').select('id, full_name').order('full_name')
  people.value = data ?? []
})
</script>

<template>
  <dialog ref="dialog" class="confirm-hire" aria-labelledby="confirm-hire-title">
    <div v-if="result" class="body">
      <div class="eyebrow">Hire confirmed</div>
      <h2 id="confirm-hire-title">Hired. Employment and the onboarding plan were created.</h2>
      <div class="actions">
        <router-link
          class="button secondary"
          :to="{ name: 'person', params: { personId: result.personId } }"
        >
          Open employee profile
        </router-link>
        <button class="button" type="button" @click="done">Done</button>
      </div>
    </div>

    <form v-else class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Recruitment</div>
      <h2 id="confirm-hire-title">Confirm hire.</h2>
      <p class="hint">
        This creates the employment period and the standard onboarding plan in one step. Retrying
        after a timeout is safe — it returns the same result.
      </p>
      <div class="field">
        <label for="ch-full-name">Full name</label>
        <input id="ch-full-name" v-model="form.fullName" required maxlength="120" />
      </div>
      <div class="field">
        <label for="ch-position">Position</label>
        <input id="ch-position" v-model="form.jobTitle" required maxlength="120" />
      </div>
      <div class="grid">
        <div class="field">
          <label for="ch-start">Start date</label>
          <input id="ch-start" v-model="form.startDate" type="date" required />
        </div>
        <div class="field">
          <label for="ch-manager">Manager (optional)</label>
          <select id="ch-manager" v-model="form.managerId">
            <option value="">No manager yet</option>
            <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
          </select>
        </div>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy">
          {{ busy ? 'Confirming…' : 'Complete hire' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.confirm-hire {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(480px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.confirm-hire::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
