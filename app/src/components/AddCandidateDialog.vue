<script setup lang="ts">
import { ref } from 'vue'
import { z } from 'zod'
import { supabase } from '@/lib/supabase'

/**
 * Adds a candidate to this job's pipeline. Candidates are recruitment
 * identities, separate from people (blueprint §5); this always creates a new
 * candidate record and immediately opens an application at the `new` stage.
 */
const props = defineProps<{ jobId: string; companyId: string }>()
const emit = defineEmits<{ created: [] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const form = ref({ fullName: '', email: '', phone: '' })
const error = ref<string | null>(null)
const busy = ref(false)

const input = z.object({
  fullName: z.string().trim().min(2, "Enter the candidate's full name.").max(120),
  email: z.union([
    z.literal(''),
    z.string().trim().toLowerCase().email('Enter a valid email or leave it empty.'),
  ]),
  phone: z.union([z.literal(''), z.string().trim().max(40, 'Keep the phone number under 40 characters.')]),
})

function open(): void {
  error.value = null
  form.value = { fullName: '', email: '', phone: '' }
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
    const { data: candidate, error: candErr } = await supabase
      .from('candidates')
      .insert({
        full_name: parsed.data.fullName,
        email: parsed.data.email || null,
        phone: parsed.data.phone || null,
      })
      .select('id')
      .single()
    if (candErr) throw new Error(friendly(candErr.message))

    const { error: appErr } = await supabase.from('applications').insert({
      job_id: props.jobId,
      company_id: props.companyId,
      candidate_id: candidate.id,
      stage_key: 'new',
    })
    if (appErr) throw new Error(friendly(appErr.message))

    dialog.value?.close()
    emit('created')
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not add the candidate.'
  } finally {
    busy.value = false
  }
}

function friendly(message: string): string {
  if (/row-level security/.test(message))
    return 'Adding a candidate needs candidates.review in this company.'
  return message
}
</script>

<template>
  <dialog ref="dialog" class="add-candidate" aria-labelledby="add-candidate-title">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Recruitment</div>
      <h2 id="add-candidate-title">Add a candidate.</h2>
      <div class="field">
        <label for="ac-name">Full name</label>
        <input id="ac-name" v-model="form.fullName" required maxlength="120" />
      </div>
      <div class="grid">
        <div class="field">
          <label for="ac-email">Email (optional)</label>
          <input id="ac-email" v-model="form.email" type="email" maxlength="320" />
        </div>
        <div class="field">
          <label for="ac-phone">Phone (optional)</label>
          <input id="ac-phone" v-model="form.phone" maxlength="40" />
        </div>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy">
          {{ busy ? 'Saving…' : 'Save candidate' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.add-candidate {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(460px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.add-candidate::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 14px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(210px, 100%), 1fr)); gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
