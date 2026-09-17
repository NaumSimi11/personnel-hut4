<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { deliverNotifications } from '@/lib/notificationsApi'
import { addressChoices, sentLine, type WelcomeNote } from '@/lib/welcome'

/**
 * The welcome note on an onboarding checklist (plan 050): built from the
 * record (position, start date, manager, the company's first-day details,
 * the published policies), previewed here, sent to the personal email by
 * default — the work mailbox may not exist yet — or the work one, filed as
 * a PDF under the person's documents, and "Welcome note sent" ticks. Copy
 * is there for when mail is not configured.
 */
const props = defineProps<{ planId: string; companyId: string }>()
const emit = defineEmits<{ changed: [] }>()

const auth = useAuthStore()
const note = ref<WelcomeNote | null>(null)
const to = ref<'personal' | 'work'>('personal')
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const open = ref(false)

const canSend = computed(() => auth.can(props.companyId, 'tasks.assign'))
const choices = computed(() => (note.value ? addressChoices(note.value) : []))

async function load(): Promise<void> {
  loading.value = true
  const { data, error: err } = await supabase.rpc('welcome_note_text', { p_plan_id: props.planId })
  loading.value = false
  if (err) {
    error.value = 'Could not build the welcome note.'
    console.error('Welcome note load failed:', err.message)
    return
  }
  note.value = data as WelcomeNote
  if (!note.value.personal_email && note.value.work_email) to.value = 'work'
}

async function send(): Promise<void> {
  error.value = null
  notice.value = null
  busy.value = true
  const { data, error: err } = await supabase.rpc('send_welcome_note', { p_plan_id: props.planId, p_to: to.value })
  busy.value = false
  if (err) {
    error.value = err.message
    return
  }
  const result = data as { to: string | null; status: string; note: string | null }
  if (result.status === 'skipped') notice.value = result.note ?? 'No address on the record; the note is in the app and filed as a PDF.'
  else {
    // Say what the delivery run reported, never more: queued until a run says sent.
    const report = await deliverNotifications()
    if (!report) notice.value = `Queued for ${result.to}; the mail service could not be reached, it goes out on the next run. The PDF is filed under the person's documents.`
    else if (report.configured === false) notice.value = `Queued for ${result.to}; email delivery is not configured yet. The PDF is filed under the person's documents.`
    else if (report.failed) notice.value = `Delivery to ${result.to} failed; check Notifications. The PDF is filed under the person's documents.`
    else if (report.sent) notice.value = `Sent to ${result.to}. The PDF is filed under the person's documents.`
    else notice.value = `Queued for ${result.to}; it goes out on the next delivery run. The PDF is filed under the person's documents.`
  }
  await load()
  emit('changed')
}

async function copy(): Promise<void> {
  if (!note.value) return
  try {
    await navigator.clipboard.writeText(`${note.value.subject}\n\n${note.value.text}`)
    notice.value = 'Copied — paste it into your mail.'
  } catch {
    error.value = 'Could not copy; select the text and copy it by hand.'
  }
}

watch(() => props.planId, load)
onMounted(load)
</script>

<template>
  <div class="card" data-testid="welcome-card">
    <div class="card-head">
      <div>
        <h2>Welcome note</h2>
        <p>Built from the record: their role, start date and manager, the first-day details, and the policies to read.</p>
      </div>
      <button type="button" class="button secondary small-btn" @click="open = !open">{{ open ? 'Hide preview' : 'Preview' }}</button>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <div v-if="loading" class="empty">Building the note…</div>
    <template v-else-if="note">
      <div v-if="open" class="preview" data-testid="welcome-preview">
        <strong>{{ note.subject }}</strong>
        <p v-for="(line, i) in note.lines" :key="i" :class="{ blank: line === '', heading: line === 'Your first day' || line === 'Our policies' }">{{ line }}</p>
      </div>
      <div class="foot">
        <small data-testid="welcome-sent">{{ sentLine(note.sent_at, note.sent_to) }}</small>
        <div v-if="canSend" class="actions">
          <select v-if="choices.length" v-model="to" aria-label="Send to" data-testid="welcome-to">
            <option v-for="c in choices" :key="c.key" :value="c.key">{{ c.label }}</option>
          </select>
          <span v-else class="muted">No email on the record.</span>
          <button type="button" class="button small-btn" :disabled="busy" data-testid="welcome-send" @click="send">{{ busy ? 'Sending…' : note.sent_at ? 'Send again' : 'Send' }}</button>
          <button type="button" class="button secondary small-btn" @click="copy">Copy</button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.in-card, .notice { margin: 12px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.preview { padding: 14px 24px; border-top: 1px solid #edf0eb; background: #fafbf8; font-size: 12px; line-height: 1.55; }
.preview strong { display: block; margin-bottom: 8px; }
.preview p { margin: 0; }
.preview p.blank { height: 8px; }
.preview p.heading { font-weight: 600; margin-top: 4px; }
.foot { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding: 12px 24px 14px; border-top: 1px solid #edf0eb; }
.foot small { font-size: 11px; color: var(--muted); }
.actions { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.actions select { border: 1px solid #dce3d7; padding: 7px 10px; font-size: 11px; background: #fff; }
.muted { font-size: 11px; color: var(--muted); }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
