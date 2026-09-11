<script setup lang="ts">
import { ref } from 'vue'
import { inviteUser, resetAccess, type AccessCredential } from '@/lib/authApi'

/**
 * Invite a new person / reissue a temporary password, ported from the Hut4
 * leave system: the credential is emailed when mail is configured AND shown
 * exactly once to the admin, so a failed email never strands an invitee.
 */
const emit = defineEmits<{ invited: [] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const mode = ref<'invite' | 'reset'>('invite')
const form = ref({ name: '', email: '' })
const resetTarget = ref<{ id: string; name: string } | null>(null)
const credential = ref<(AccessCredential & { email: string; name: string }) | null>(null)
const error = ref<string | null>(null)
const busy = ref(false)
const copied = ref(false)

function openInvite(): void {
  mode.value = 'invite'
  form.value = { name: '', email: '' }
  credential.value = null
  error.value = null
  dialog.value?.showModal()
}

function openReset(person: { id: string; name: string }): void {
  mode.value = 'reset'
  resetTarget.value = person
  credential.value = null
  error.value = null
  dialog.value?.showModal()
}

defineExpose({ openInvite, openReset })

async function submit(): Promise<void> {
  error.value = null
  busy.value = true
  copied.value = false
  try {
    if (mode.value === 'invite') {
      const result = await inviteUser({
        name: form.value.name.trim(),
        email: form.value.email.trim().toLowerCase(),
      })
      credential.value = { ...result, email: form.value.email.trim(), name: form.value.name.trim() }
      emit('invited')
    } else if (resetTarget.value) {
      const result = await resetAccess(resetTarget.value.id)
      credential.value = { ...result, name: resetTarget.value.name }
    }
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'The request failed.'
  } finally {
    busy.value = false
  }
}

async function copyPassword(): Promise<void> {
  if (!credential.value) return
  try {
    await navigator.clipboard.writeText(credential.value.tempPassword)
    copied.value = true
  } catch {
    copied.value = false
  }
}

function close(): void {
  credential.value = null
  dialog.value?.close()
}
</script>

<template>
  <dialog ref="dialog" class="invite-dialog" aria-labelledby="invite-title">
    <!-- Step 2: the credential, shown exactly once. -->
    <div v-if="credential" class="body">
      <div class="eyebrow">{{ mode === 'invite' ? 'Invitation created' : 'Access reset' }}</div>
      <h2 id="invite-title">One-time temporary password for {{ credential.name }}</h2>
      <p class="hint">
        {{
          credential.emailSent
            ? `It was also emailed to ${credential.email}.`
            : `Email delivery is not configured — pass it on yourself. It stops working the moment they replace it at first sign-in.`
        }}
      </p>
      <div class="credential"><code>{{ credential.tempPassword }}</code></div>
      <div class="actions">
        <button class="button secondary" type="button" @click="copyPassword">
          {{ copied ? 'Copied ✓' : 'Copy password' }}
        </button>
        <button class="button" type="button" @click="close">Done</button>
      </div>
      <p class="hint">This is the only time it is shown; it is never stored.</p>
    </div>

    <!-- Step 1: the form / confirmation. -->
    <form v-else class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">{{ mode === 'invite' ? 'Invite to Personnel' : 'Reset access' }}</div>
      <h2 id="invite-title">
        {{ mode === 'invite' ? 'Create an account by invitation.' : `New temporary password for ${resetTarget?.name}?` }}
      </h2>
      <template v-if="mode === 'invite'">
        <div class="field">
          <label for="invite-name">Full name</label>
          <input id="invite-name" v-model="form.name" required maxlength="120" />
        </div>
        <div class="field">
          <label for="invite-email">Work email</label>
          <input id="invite-email" v-model="form.email" type="email" required maxlength="320" />
        </div>
        <p class="hint">
          Only company addresses are accepted. The account starts with a temporary password and a
          forced change on first sign-in.
        </p>
      </template>
      <p v-else class="hint">
        “Never got the invitation” and “forgot the password” are the same operation: their old
        password stops working now, and the new temporary one must be replaced at next sign-in.
      </p>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="close">Cancel</button>
        <button class="button" type="submit" :disabled="busy">
          {{ busy ? 'Working…' : mode === 'invite' ? 'Create invitation' : 'Reset access' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.invite-dialog {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(460px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.invite-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 14px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; }
.credential {
  background: #f4f6f0;
  border: 1px dashed #d5dfca;
  border-radius: 9px;
  padding: 14px 16px;
  margin: 14px 0;
  text-align: center;
}
.credential code { font-size: 17px; letter-spacing: 0.04em; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 16px; }
</style>
