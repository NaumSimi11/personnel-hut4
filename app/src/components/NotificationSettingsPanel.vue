<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'

/**
 * Where HR-side mail goes for this company (plan 043, Field Notebook's
 * "active HR recipient"): one shared inbox when set, otherwise each
 * approver's own work email. Admin-only by RLS on companies.
 */
const props = defineProps<{ companyId: string }>()

const email = ref('')
const saved = ref('')
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const busy = ref(false)

async function load(): Promise<void> {
  const { data, error: err } = await supabase.from('companies').select('hr_notification_email').eq('id', props.companyId).maybeSingle()
  if (err) {
    error.value = 'Could not load the notification settings.'
    console.error('Notification settings load failed:', err.message)
    return
  }
  email.value = data?.hr_notification_email ?? ''
  saved.value = email.value
}

async function save(): Promise<void> {
  error.value = null
  notice.value = null
  const value = email.value.trim().toLowerCase()
  if (value && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
    error.value = 'Enter a valid email address, or leave it empty.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.from('companies').update({ hr_notification_email: value || null }).eq('id', props.companyId).select('id').maybeSingle()
  busy.value = false
  if (err || !data) {
    error.value = !err || err.message.includes('row-level security') ? 'Only platform admins change notification settings.' : err.message
    return
  }
  saved.value = value
  email.value = value
  notice.value = value ? `HR notifications for this company go to ${value}.` : 'HR notifications go to each approver’s own work email.'
}

watch(() => props.companyId, load)
onMounted(load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Notifications</h2>
        <p>Requests to approve, asks to cancel and submitted documents are announced to whoever approves them here. People always hear about their own requests at their work email.</p>
      </div>
    </div>
    <form class="card-body" novalidate @submit.prevent="save">
      <div class="field">
        <label for="hr-notification-email">HR inbox for this company (optional)</label>
        <input id="hr-notification-email" v-model="email" type="email" placeholder="hr@company.com — empty: each approver’s own address" maxlength="320" />
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <p v-if="notice" class="notice" role="status">{{ notice }}</p>
      <button class="button" type="submit" :disabled="busy || email.trim().toLowerCase() === saved">{{ busy ? 'Saving…' : 'Save' }}</button>
    </form>
  </div>
</template>

<style scoped>
.notice { padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin: 0 0 12px; }
</style>
