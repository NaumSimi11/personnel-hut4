<script setup lang="ts">
import { ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { personBasicsInput, type PersonBasicsForm } from '@/lib/employeeForm'

/**
 * Edit the basics of a person record where they are shown (plan 046): name,
 * preferred name, work and personal email, phone. RLS (can_edit_person)
 * decides who may — admins and employment.edit holders in a company the
 * person is employed by.
 */
export type PersonBasics = {
  id: string
  full_name: string
  preferred_name: string | null
  work_email: string | null
  personal_email: string | null
  phone: string | null
}

const emit = defineEmits<{ saved: [person: PersonBasics] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const personId = ref('')
const form = ref<PersonBasicsForm>({ fullName: '', preferredName: '', workEmail: '', personalEmail: '', phone: '' })
const error = ref<string | null>(null)
const busy = ref(false)

function open(person: PersonBasics): void {
  personId.value = person.id
  form.value = {
    fullName: person.full_name,
    preferredName: person.preferred_name ?? '',
    workEmail: person.work_email ?? '',
    personalEmail: person.personal_email ?? '',
    phone: person.phone ?? '',
  }
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

async function submit(): Promise<void> {
  error.value = null
  const parsed = personBasicsInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  const patch = {
    full_name: parsed.data.fullName,
    preferred_name: parsed.data.preferredName || null,
    work_email: parsed.data.workEmail || null,
    personal_email: parsed.data.personalEmail || null,
    phone: parsed.data.phone || null,
  }
  const { data, error: err } = await supabase.from('people').update(patch).eq('id', personId.value).select('id').maybeSingle()
  busy.value = false
  if (err || !data) {
    error.value = friendly(err?.code ?? '', err?.message ?? '')
    return
  }
  dialog.value?.close()
  emit('saved', { id: personId.value, ...patch })
}

/** 23505 = people_work_email_key (0039); no row back = RLS said no. */
function friendly(code: string, message: string): string {
  if (code === '23505') return 'Another person already has that work email.'
  if (!message || /row-level security/.test(message)) return "Editing these details needs employment.edit in the person's company."
  return message
}
</script>

<template>
  <dialog ref="dialog" class="edit-person" aria-labelledby="edit-person-title" data-testid="edit-person-dialog">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Employee record</div>
      <h2 id="edit-person-title">Edit details.</h2>
      <p class="hint">The basics of the record. Employment facts are corrected or changed from the employment row.</p>
      <div class="grid">
        <div class="field">
          <label for="ep-name">Full name</label>
          <input id="ep-name" v-model="form.fullName" required maxlength="120" />
        </div>
        <div class="field">
          <label for="ep-preferred">Preferred name</label>
          <input id="ep-preferred" v-model="form.preferredName" maxlength="60" />
        </div>
        <div class="field">
          <label for="ep-work-email">Work email</label>
          <input id="ep-work-email" v-model="form.workEmail" type="email" maxlength="320" />
        </div>
        <div class="field">
          <label for="ep-personal-email">Personal email</label>
          <input id="ep-personal-email" v-model="form.personalEmail" type="email" maxlength="320" />
        </div>
        <div class="field">
          <label for="ep-phone">Personal phone</label>
          <input id="ep-phone" v-model="form.phone" maxlength="40" />
        </div>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy">{{ busy ? 'Saving…' : 'Save details' }}</button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.edit-person {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(520px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.edit-person::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
