<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { OFFER_TOKEN, answerOffer, fetchOffer, offerState, salaryLine, type CandidateOffer } from '@/lib/offerApi'

/**
 * The candidate's offer (0106; spec 6.5, screen 9.12). Public, reached from
 * the emailed link; no sign-in, no app shell. Accepting is one click with a
 * confirmation; declining asks for a reason.
 */
const route = useRoute()
const token = computed(() => String(route.params.token ?? ''))
const offer = ref<CandidateOffer | null>(null)
const loading = ref(true)
const error = ref<string | null>(null)
const busy = ref(false)
const mode = ref<'view' | 'confirm-accept' | 'decline'>('view')
const reason = ref('')
const done = ref<'accepted' | 'declined' | null>(null)

const state = computed(() => (offer.value ? offerState(offer.value) : null))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  if (!OFFER_TOKEN.test(token.value)) {
    loading.value = false
    error.value = 'This offer link is not valid. Check that you copied the whole link from the email.'
    return
  }
  try {
    offer.value = await fetchOffer(token.value)
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'The offer could not be loaded.'
  } finally {
    loading.value = false
  }
}

async function send(answer: 'accepted' | 'declined'): Promise<void> {
  if (answer === 'declined' && reason.value.trim().length < 3) {
    error.value = 'Tell us briefly why you are declining.'
    return
  }
  busy.value = true
  error.value = null
  try {
    await answerOffer(token.value, answer, answer === 'declined' ? reason.value : undefined)
    done.value = answer
    await load()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Your answer could not be saved. Try again.'
  } finally {
    busy.value = false
  }
}

onMounted(load)
</script>

<template>
  <main class="offer-page">
    <div class="offer-card" aria-live="polite">
      <p v-if="loading" class="muted">Loading your offer…</p>
      <template v-else-if="offer">
        <div class="eyebrow">{{ offer.company }}</div>
        <h1>Your offer: {{ offer.job }}</h1>
        <p>Dear {{ offer.candidate }},</p>

        <dl class="terms">
          <template v-if="salaryLine(offer)"><dt>Salary</dt><dd>{{ salaryLine(offer) }}</dd></template>
          <template v-if="offer.employment_type"><dt>Employment</dt><dd>{{ offer.employment_type }}</dd></template>
          <template v-if="offer.start_date"><dt>Start date</dt><dd>{{ offer.start_date }}</dd></template>
          <template v-if="offer.bonus"><dt>Bonus</dt><dd>{{ offer.bonus }}</dd></template>
          <template v-if="offer.expires_on"><dt>Answer by</dt><dd>{{ offer.expires_on }}</dd></template>
        </dl>
        <div v-if="offer.benefits" class="notes"><strong>Benefits</strong><p>{{ offer.benefits }}</p></div>
        <div v-if="offer.conditions" class="notes"><strong>Conditions</strong><p>{{ offer.conditions }}</p></div>

        <p v-if="state === 'accepted'" class="result ok" role="status">
          {{ done === 'accepted' ? 'Thank you — you accepted the offer.' : 'You accepted this offer.' }}
          We will be in touch about your contract and first day.
        </p>
        <p v-else-if="state === 'declined'" class="result" role="status">
          {{ done === 'declined' ? 'Thank you for letting us know.' : 'You declined this offer.' }}
        </p>
        <p v-else-if="state === 'expired'" class="result" role="status">
          This offer expired on {{ offer.expires_on }}. If you are still interested, please reply to the email it came with.
        </p>

        <template v-else>
          <div v-if="mode === 'view'" class="actions">
            <button class="btn primary" type="button" :disabled="busy" @click="mode = 'confirm-accept'">Accept the offer</button>
            <button class="btn" type="button" :disabled="busy" @click="mode = 'decline'">Decline</button>
          </div>
          <div v-else-if="mode === 'confirm-accept'" class="confirm">
            <p>Accept the offer for {{ offer.job }} at {{ offer.company }}?</p>
            <div class="actions">
              <button class="btn primary" type="button" :disabled="busy" data-testid="offer-accept" @click="send('accepted')">
                {{ busy ? 'Saving…' : 'Yes, I accept' }}
              </button>
              <button class="btn" type="button" :disabled="busy" @click="mode = 'view'">Back</button>
            </div>
          </div>
          <form v-else class="confirm" novalidate @submit.prevent="send('declined')">
            <label for="decline-reason">Why are you declining? It helps us.</label>
            <textarea id="decline-reason" v-model="reason" rows="4" maxlength="2000" :disabled="busy"></textarea>
            <div class="actions">
              <button class="btn danger" type="submit" :disabled="busy" data-testid="offer-decline">{{ busy ? 'Saving…' : 'Decline the offer' }}</button>
              <button class="btn" type="button" :disabled="busy" @click="mode = 'view'">Back</button>
            </div>
          </form>
        </template>
      </template>
      <p v-if="error" class="error" role="alert">{{ error }}</p>
    </div>
  </main>
</template>

<style scoped>
.offer-page {
  --bg: #f4f6f3; --card: #ffffff; --fg: #1b231e; --muted: #5d6b62; --line: #dde3dc; --accent: #2f6b4a; --danger: #a33a2c;
  min-height: 100%;
  background: var(--bg);
  color: var(--fg);
  padding-block: 40px;
  padding-left: max(16px, env(safe-area-inset-left, 0px));
  padding-right: max(16px, env(safe-area-inset-right, 0px));
  font-family: Inter, system-ui, -apple-system, sans-serif;
}
@media (prefers-color-scheme: dark) {
  .offer-page { --bg: #121714; --card: #1a211d; --fg: #e5ebe6; --muted: #9aa89f; --line: #2b352f; --accent: #7cc49c; --danger: #f08a7c; }
}
.offer-card { max-width: 560px; margin: 0 auto; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 28px; display: grid; gap: 14px; }
.eyebrow { font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); font-weight: 600; }
h1 { margin: 0; font-size: 1.6rem; text-wrap: balance; }
p { margin: 0; }
.muted { color: var(--muted); }
.terms { display: grid; grid-template-columns: max-content 1fr; gap: 6px 16px; margin: 0; }
.terms dt { color: var(--muted); }
.terms dd { margin: 0; font-weight: 600; font-variant-numeric: tabular-nums; }
.notes { white-space: pre-line; color: var(--muted); }
.actions { display: flex; gap: 10px; flex-wrap: wrap; }
.confirm { display: grid; gap: 10px; }
textarea { width: 100%; font: inherit; padding: 8px; border-radius: 8px; border: 1px solid var(--line); background: transparent; color: inherit; }
.btn { font: inherit; padding: 9px 16px; border-radius: 999px; border: 1px solid var(--line); background: transparent; color: var(--fg); cursor: pointer; }
.btn.primary { background: var(--accent); border-color: var(--accent); color: var(--card); }
.btn.danger { border-color: var(--danger); color: var(--danger); }
.btn:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.result { padding: 12px; border-radius: 10px; background: var(--bg); }
.result.ok { border-left: 3px solid var(--accent); }
.error { color: var(--danger); }
</style>
