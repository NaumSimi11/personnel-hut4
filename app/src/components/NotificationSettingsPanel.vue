<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'

/**
 * Where HR-side and IT-side mail goes for this company (plans 043, 048):
 * one shared inbox each when set, otherwise the approvers' / the IT
 * owner's own work email. Admin-only by RLS on companies.
 */
const props = defineProps<{ companyId: string }>()

const hrEmail = ref('')
const itEmail = ref('')
const saved = ref({ hr: '', it: '' })
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const busy = ref(false)

const unchanged = computed(() => hrEmail.value.trim().toLowerCase() === saved.value.hr && itEmail.value.trim().toLowerCase() === saved.value.it)

async function load(): Promise<void> {
  const { data, error: err } = await supabase.from('companies').select('hr_notification_email, it_notification_email').eq('id', props.companyId).maybeSingle()
  if (err) {
    error.value = 'Could not load the notification settings.'
    console.error('Notification settings load failed:', err.message)
    return
  }
  hrEmail.value = data?.hr_notification_email ?? ''
  itEmail.value = data?.it_notification_email ?? ''
  saved.value = { hr: hrEmail.value, it: itEmail.value }
}

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

async function save(): Promise<void> {
  error.value = null
  notice.value = null
  const hr = hrEmail.value.trim().toLowerCase()
  const it = itEmail.value.trim().toLowerCase()
  if ((hr && !EMAIL.test(hr)) || (it && !EMAIL.test(it))) {
    error.value = 'Enter valid email addresses, or leave them empty.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase
    .from('companies')
    .update({ hr_notification_email: hr || null, it_notification_email: it || null })
    .eq('id', props.companyId)
    .select('id')
    .maybeSingle()
  busy.value = false
  if (err || !data) {
    error.value = !err || err.message.includes('row-level security') ? 'Only platform admins change notification settings.' : err.message
    return
  }
  saved.value = { hr, it }
  hrEmail.value = hr
  itEmail.value = it
  notice.value = [
    hr ? `HR notifications go to ${hr}.` : 'HR notifications go to each approver’s own work email.',
    it ? `IT requests and handovers go to ${it}.` : 'IT mail goes to the IT owner’s own work email.',
  ].join(' ')
}

watch(() => props.companyId, load)
onMounted(load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Notifications</h2>
        <p>Requests to approve, asks to cancel and submitted documents are announced to whoever approves them here; IT requests and handovers to IT. People always hear about their own requests at their work email.</p>
      </div>
    </div>
    <form class="card-body" novalidate @submit.prevent="save">
      <div class="field">
        <label for="hr-notification-email">HR inbox for this company (optional)</label>
        <input id="hr-notification-email" v-model="hrEmail" type="email" placeholder="hr@company.com — empty: each approver’s own address" maxlength="320" />
      </div>
      <div class="field">
        <label for="it-notification-email">IT inbox for this company (optional)</label>
        <input id="it-notification-email" v-model="itEmail" type="email" placeholder="it@company.com — empty: the IT owner’s own address" maxlength="320" />
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <p v-if="notice" class="notice" role="status">{{ notice }}</p>
      <button class="button" type="submit" :disabled="busy || unchanged">{{ busy ? 'Saving…' : 'Save' }}</button>
    </form>
  </div>
</template>

<style scoped>
.notice { padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin: 0 0 12px; }
</style>
