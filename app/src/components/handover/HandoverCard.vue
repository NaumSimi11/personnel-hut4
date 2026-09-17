<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { deliverHandover } from '@/lib/notificationsApi'
import { eventLabel, light, messageForHandover, sendLine, type HandoverSend } from '@/lib/handover'

/**
 * The Handover card on a checklist (plan 048): one row per recipient per
 * event with a traffic light — green sent or sent by hand, red failed or
 * missing something (named), grey queued — and the actions HR asked for:
 * Resend (rebuilds from the record now — "fill it and resend"), Mark as
 * sent, Retry, and "What was sent". Reading needs tasks.view; the actions
 * tasks.assign (the RPCs check again).
 */
const props = defineProps<{ planId: string; personId: string; companyId: string; kind: 'onboarding' | 'offboarding' }>()
const emit = defineEmits<{ changed: [] }>()

type Row = HandoverSend & { created_at: string }

const auth = useAuthStore()
const sends = ref<Row[]>([])
const loading = ref(true)
const busyId = ref<string | null>(null)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const open = ref<Set<string>>(new Set())

const canWork = computed(() => auth.can(props.companyId, 'tasks.assign'))
const events = computed(() => {
  const order = props.kind === 'onboarding' ? ['hire_confirmed', 'onboarding_finished'] : ['departure_scheduled', 'marked_former']
  return order.map((e) => ({ key: e, sends: sends.value.filter((s) => s.event === e) })).filter((g) => g.sends.length)
})

async function load(): Promise<void> {
  loading.value = true
  const { data, error: err } = await supabase
    .from('handover_sends')
    .select('id, event, recipient_label, to_email, fields, stripped, missing, status, error, sent_at, marked_by, created_at')
    .eq('person_id', props.personId)
    .eq('company_id', props.companyId)
    .order('created_at')
  loading.value = false
  if (err) {
    error.value = 'Could not load the handover.'
    console.error('Handover load failed:', err.message)
    return
  }
  sends.value = (data ?? []) as Row[]
}

async function act(s: Row, fn: 'resend_handover' | 'mark_handover_sent' | 'retry_handover'): Promise<void> {
  error.value = null
  notice.value = null
  busyId.value = s.id
  const { data, error: err } = await supabase.rpc(fn, { p_id: s.id })
  busyId.value = null
  if (err) {
    error.value = messageForHandover(err)
    return
  }
  const result = data as { status: string; missing?: string[] }
  if (fn === 'mark_handover_sent') notice.value = `${s.recipient_label} marked as sent.`
  else if (result.status === 'missing') notice.value = `${s.recipient_label} still needs ${(result.missing ?? []).join(', ')}.`
  else {
    const report = await deliverHandover()
    notice.value = report?.configured === false ? `${s.recipient_label} is queued; email delivery is not configured yet.` : `${s.recipient_label} queued and sent.`
  }
  await load()
  // A green send may have ticked the checklist line.
  emit('changed')
}

function toggle(id: string): void {
  const next = new Set(open.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  open.value = next
}

watch(() => props.personId, load)
onMounted(load)
</script>

<template>
  <div class="card" data-testid="handover-card">
    <div class="card-head">
      <div>
        <h2>Handover</h2>
        <p>Who was told what. Green went; red did not — fill what is missing on the record and resend, or mark it sent by hand.</p>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <div v-if="loading" class="empty">Loading handover…</div>
    <div v-else-if="!sends.length" class="empty">Nothing to send yet — no recipients are configured for this company's events.</div>
    <div v-for="group in events" :key="group.key" class="group">
      <h3 class="group-heading">On {{ eventLabel(group.key) }}</h3>
      <div v-for="s in group.sends" :key="s.id" class="send" :data-testid="`send-${s.id}`" :data-status="s.status">
        <span class="light" :class="light(s.status)" :aria-label="light(s.status)"></span>
        <div class="text">
          <strong>{{ s.recipient_label }}<small v-if="s.to_email" class="addr"> · {{ s.to_email }}</small></strong>
          <small :class="{ red: light(s.status) === 'red' }" data-testid="send-line">{{ sendLine(s) }}</small>
          <small v-if="s.stripped.length" class="muted">Withheld (not trusted for it): {{ s.stripped.join(', ') }}</small>
          <div v-if="open.has(s.id)" class="snapshot">
            <table>
              <tbody>
                <tr v-for="(f, key) in s.fields" :key="key"><td>{{ f.label }}</td><td>{{ f.value }}</td></tr>
              </tbody>
            </table>
            <small v-if="!Object.keys(s.fields).length" class="muted">Nothing on file for the configured fields.</small>
          </div>
        </div>
        <div class="actions">
          <button type="button" class="link-button" @click="toggle(s.id)">{{ open.has(s.id) ? 'Hide' : 'What was sent' }}</button>
          <template v-if="canWork && s.status !== 'cancelled'">
            <button type="button" class="button secondary small-btn" :disabled="busyId === s.id" data-testid="resend" @click="act(s, 'resend_handover')">Resend</button>
            <button v-if="s.status === 'failed'" type="button" class="button secondary small-btn" :disabled="busyId === s.id" @click="act(s, 'retry_handover')">Retry</button>
            <button v-if="s.status !== 'sent' && s.status !== 'manual'" type="button" class="button secondary small-btn" :disabled="busyId === s.id" data-testid="mark-sent" @click="act(s, 'mark_handover_sent')">Mark as sent</button>
          </template>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.in-card, .notice { margin: 14px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.group-heading { font-size: 11px; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin: 14px 24px 0; }
.send { display: flex; align-items: flex-start; gap: 12px; padding: 12px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.light { flex: 0 0 12px; width: 12px; height: 12px; border-radius: 50%; margin-top: 4px; }
.light.green { background: #3e9a5f; box-shadow: 0 0 0 3px #e6f2e9; }
.light.red { background: var(--red); box-shadow: 0 0 0 3px #fbeaea; }
.light.grey { background: #b8c2bb; box-shadow: 0 0 0 3px #eef1ec; }
.text { flex: 1; min-width: 220px; }
.text strong { display: block; font-size: 12px; font-weight: 550; }
.text .addr { font-weight: 400; color: var(--muted); }
.text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.text small.red { color: var(--red); font-weight: 600; }
.snapshot { margin-top: 8px; }
.snapshot table { font-size: 11px; border-collapse: collapse; }
.snapshot td { padding: 3px 10px 3px 0; vertical-align: top; }
.snapshot td:first-child { color: var(--muted); }
.actions { display: flex; gap: 7px; flex-wrap: wrap; align-items: center; }
.link-button { border: 0; background: none; color: var(--green); font-size: 11px; padding: 0; cursor: pointer; text-decoration: underline; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
