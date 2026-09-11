<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { meetsPasswordPolicy, PASSWORD_POLICY_SUMMARY, PASSWORD_RULES } from '@shared/passwordPolicy'
import { changePassword } from '@/lib/authApi'
import { useAuthStore } from '@/stores/auth'

/**
 * Forced first-login password change, ported from the Hut4 leave system.
 * While the session carries the must-change flag, the router redirects here
 * and the database refuses every query — this screen is the only way forward.
 */
const auth = useAuthStore()
const router = useRouter()

const current = ref('')
const next = ref('')
const confirm = ref('')
const error = ref<string | null>(null)
const busy = ref(false)

const differsFromTemp = computed(() => next.value.length > 0 && next.value !== current.value)
const entriesMatch = computed(() => confirm.value.length > 0 && next.value === confirm.value)

async function submit() {
  error.value = null
  if (!meetsPasswordPolicy(next.value)) {
    error.value = PASSWORD_POLICY_SUMMARY
    return
  }
  if (next.value === current.value) {
    error.value = 'Choose a password different from the temporary one.'
    return
  }
  if (next.value !== confirm.value) {
    error.value = 'The new passwords do not match.'
    return
  }
  busy.value = true
  try {
    const email = auth.session?.user.email
    if (!email) throw new Error('Your session expired — sign in again.')
    await changePassword({ currentPassword: current.value, newPassword: next.value })
    // Re-mint the session (same as the leave system does): an admin-side
    // password change can revoke tokens, so a fresh sign-in with the new
    // password is the only reliable way to a JWT without the must-change flag.
    await auth.signOut()
    await auth.signIn(email, next.value)
    router.push({ name: 'overview' })
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not change the password.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="gate-wrap">
    <div class="card gate-card">
      <div class="card-body">
        <div class="eyebrow">Hut4 HR · first sign-in</div>
        <h1>Choose your<br /><em>own password.</em></h1>
        <p class="sub">
          The temporary password you were given is single-use. Pick your own to continue.
        </p>
        <form novalidate @submit.prevent="submit">
          <div class="field">
            <label for="current">Temporary password</label>
            <input id="current" v-model="current" type="password" autocomplete="current-password" />
          </div>
          <div class="field">
            <label for="next">New password</label>
            <input id="next" v-model="next" type="password" autocomplete="new-password" />
          </div>
          <ul class="password-rules" aria-label="Password requirements">
            <li v-for="rule in PASSWORD_RULES" :key="rule.id" :class="{ met: rule.test(next) }">
              <span aria-hidden="true">{{ rule.test(next) ? '✓' : '○' }}</span> {{ rule.label }}
            </li>
            <li :class="{ met: differsFromTemp }">
              <span aria-hidden="true">{{ differsFromTemp ? '✓' : '○' }}</span>
              Different from the temporary password
            </li>
            <li :class="{ met: entriesMatch }">
              <span aria-hidden="true">{{ entriesMatch ? '✓' : '○' }}</span> Both entries match
            </li>
          </ul>
          <div class="field">
            <label for="confirm">Repeat new password</label>
            <input id="confirm" v-model="confirm" type="password" autocomplete="new-password" />
          </div>
          <p v-if="error" class="error-note" role="alert">{{ error }}</p>
          <button class="button" type="submit" :disabled="busy">
            {{ busy ? 'Saving…' : 'Set password' }}
          </button>
        </form>
      </div>
    </div>
  </div>
</template>

<style scoped>
.gate-wrap {
  min-height: 100vh;
  display: grid;
  place-items: center;
  padding: 20px;
  background:
    radial-gradient(circle at 80% 15%, #edf4ef 0%, transparent 55%),
    var(--bg);
}
.gate-card { width: min(440px, 100%); }
h1 em { font-style: normal; color: var(--green); }
.sub { color: var(--muted); font-size: 12px; margin: 0 0 22px; }
.password-rules {
  list-style: none;
  margin: 0 0 17px;
  padding: 12px 15px;
  border: 1px dashed var(--line);
  border-radius: 9px;
  display: grid;
  gap: 6px;
}
.password-rules li { font-size: 11px; color: var(--muted); display: flex; gap: 8px; }
.password-rules li.met { color: #3e744e; }
form .button { width: 100%; }
</style>
