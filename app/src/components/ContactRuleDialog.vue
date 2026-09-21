<script setup lang="ts">
import { ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { todayDb } from '@/lib/compensation'
import type { Json } from '@/types/database'

/**
 * The contact rule on a candidate's record (plan 052): ok, later (with an
 * optional "not before" date) or never (with the reason everyone who tries
 * to add them to a job will read). Saved through set_contact_rule, which
 * decides who may change it and returns its refusals as sentences.
 */

export type ContactRuleCandidate = {
  id: string
  full_name: string
  do_not_contact: boolean
  do_not_contact_reason: string | null
  contact_later: boolean
  contact_again_after: string | null
}

type Rule = 'ok' | 'later' | 'never'

const emit = defineEmits<{ saved: [] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const candidate = ref<ContactRuleCandidate | null>(null)
const rule = ref<Rule>('ok')
const after = ref('')
const reason = ref('')
const error = ref<string | null>(null)
const busy = ref(false)

function currentRule(c: ContactRuleCandidate): Rule {
  if (c.do_not_contact) return 'never'
  if (c.contact_later) return 'later'
  return 'ok'
}

function open(next: ContactRuleCandidate): void {
  candidate.value = next
  rule.value = currentRule(next)
  after.value = next.contact_later ? (next.contact_again_after ?? '') : ''
  reason.value = next.do_not_contact ? (next.do_not_contact_reason ?? '') : ''
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

async function submit(): Promise<void> {
  if (!candidate.value) return
  error.value = null
  if (rule.value === 'never' && !reason.value.trim()) {
    error.value = 'Say why this person must not be contacted again.'
    return
  }
  busy.value = true
  const payload = {
    rule: rule.value,
    ...(rule.value === 'later' && { contact_again_after: after.value || null }),
    ...(rule.value === 'never' && { reason: reason.value.trim() }),
  }
  const { error: err } = await supabase.rpc('set_contact_rule', { p_candidate_id: candidate.value.id, p: payload as Json })
  busy.value = false
  if (err) {
    error.value = err.message
    return
  }
  dialog.value?.close()
  emit('saved')
}
</script>

<template>
  <dialog ref="dialog" class="contact-rule" aria-labelledby="contact-rule-title" data-testid="contact-rule">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Talent pool</div>
      <h2 id="contact-rule-title">How may we contact {{ candidate?.full_name ?? 'this person' }}?</h2>
      <p class="hint">Never blocks every "Add to job" for this person until the rule is changed. Contact later only warns.</p>

      <fieldset class="rules" :disabled="busy">
        <label class="rule">
          <input v-model="rule" type="radio" name="contact-rule" value="ok" data-testid="contact-rule-ok" />
          <span><b>Can be contacted</b></span>
        </label>
        <label class="rule">
          <input v-model="rule" type="radio" name="contact-rule" value="later" data-testid="contact-rule-later" />
          <span><b>Contact later</b></span>
        </label>
        <div v-if="rule === 'later'" class="field nested">
          <label for="contact-rule-after">Not before (optional)</label>
          <input id="contact-rule-after" v-model="after" type="date" :min="todayDb()" data-testid="contact-rule-after" />
        </div>
        <label class="rule">
          <input v-model="rule" type="radio" name="contact-rule" value="never" data-testid="contact-rule-never" />
          <span><b>Never contact again</b></span>
        </label>
        <div v-if="rule === 'never'" class="field nested">
          <label for="contact-rule-reason">Why? Everyone who tries to add them to a job sees this.</label>
          <textarea id="contact-rule-reason" v-model="reason" rows="3" maxlength="1000" required data-testid="contact-rule-reason"></textarea>
        </div>
      </fieldset>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" :class="{ danger: rule === 'never' }" type="submit" :disabled="busy" data-testid="contact-rule-save">
          {{ busy ? 'Saving…' : 'Save' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.contact-rule {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(460px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.contact-rule::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.rules { border: 0; padding: 0; margin: 0; display: grid; gap: 10px; }
.rule { display: flex; align-items: center; gap: 9px; font-size: 13px; cursor: pointer; }
.rule b { font-weight: 600; }
.nested { margin: 0 0 6px 25px; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.danger { background: var(--red); border-color: var(--red); }
.danger:hover { background: #8f3838; }
</style>
