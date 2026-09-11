<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { z } from 'zod'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const router = useRouter()

const email = ref('')
const password = ref('')
const error = ref<string | null>(null)
const busy = ref(false)

const credentials = z.object({
  email: z.string().email('Enter a valid email address.'),
  password: z.string().min(1, 'Enter your password.'),
})

async function submit() {
  error.value = null
  const parsed = credentials.safeParse({ email: email.value.trim(), password: password.value })
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check your input.'
    return
  }
  busy.value = true
  try {
    await auth.signIn(parsed.data.email, parsed.data.password)
    router.push({ name: 'directory' })
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Sign-in failed. Try again.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="login-wrap">
    <div class="card login-card">
      <div class="card-body">
        <div class="eyebrow">Personnel · Hut4</div>
        <h1>Sign in to your workspace.</h1>
        <p class="sub">One workspace for the whole holding. Access is granted per company.</p>
        <form novalidate @submit.prevent="submit">
          <div class="field">
            <label for="email">Work email</label>
            <input id="email" v-model="email" type="email" autocomplete="username" required />
          </div>
          <div class="field">
            <label for="password">Password</label>
            <input
              id="password"
              v-model="password"
              type="password"
              autocomplete="current-password"
              required
            />
          </div>
          <p v-if="error" class="error-note" role="alert">{{ error }}</p>
          <button class="button" type="submit" :disabled="busy">
            {{ busy ? 'Signing in…' : 'Sign in' }}
          </button>
          <p class="invite-note">🔒 Accounts are created by invitation only.</p>
        </form>
      </div>
    </div>
  </div>
</template>

<style scoped>
.login-wrap {
  min-height: 100vh;
  display: grid;
  place-items: center;
  padding: 20px;
  background:
    radial-gradient(circle at 20% 20%, #edf4ef 0%, transparent 55%),
    var(--bg);
}
.login-card { width: min(420px, 100%); }
.sub { color: var(--muted); font-size: 12px; margin: 0 0 22px; }
form .button { width: 100%; margin-top: 4px; }
.invite-note { font-size: 11px; color: var(--muted); text-align: center; margin: 14px 0 0; }
</style>
