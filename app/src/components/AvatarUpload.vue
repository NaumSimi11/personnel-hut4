<script setup lang="ts">
import { ref } from 'vue'
import AvatarImage from '@/components/AvatarImage.vue'
import { AVATAR_ACCEPT, removeAvatar, uploadAvatar, validateAvatarFile } from '@/lib/avatars'

/**
 * The photo on a profile with the means to change it: click the picture (or
 * the button) to pick an image; it is squared and shrunk in the browser,
 * stored, and the record updated. Whether the viewer may do this is the
 * database's call (set_avatar); the control only shows when `editable`.
 */
const props = defineProps<{ personId: string; name: string; path: string | null; editable: boolean }>()
const emit = defineEmits<{ changed: [path: string | null] }>()

const input = ref<HTMLInputElement | null>(null)
const busy = ref(false)
const error = ref<string | null>(null)

async function onPick(event: Event): Promise<void> {
  const el = event.target as HTMLInputElement
  const file = el.files?.[0]
  el.value = ''
  if (!file) return
  const problem = validateAvatarFile(file)
  if (problem) {
    error.value = problem
    return
  }
  busy.value = true
  error.value = null
  try {
    const path = await uploadAvatar(props.personId, file)
    emit('changed', path)
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not upload the photo.'
    console.error('Avatar upload failed:', error.value)
  } finally {
    busy.value = false
  }
}

async function remove(): Promise<void> {
  if (!window.confirm('Remove the photo?')) return
  busy.value = true
  error.value = null
  try {
    await removeAvatar(props.personId)
    emit('changed', null)
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not remove the photo.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="avatar-upload" :class="{ editable }">
    <button v-if="editable" class="pick" type="button" :disabled="busy" :aria-label="path ? 'Change photo' : 'Add photo'" @click="input?.click()">
      <AvatarImage :name="name" :path="path" size="big" />
      <span class="overlay">
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M2 5.5h2.2l1-1.7h5.6l1 1.7H14v7.5H2z" /><circle cx="8" cy="9" r="2.4" />
        </svg>
        {{ busy ? 'Saving…' : path ? 'Change' : 'Add photo' }}
      </span>
    </button>
    <AvatarImage v-else :name="name" :path="path" size="big" />
    <input ref="input" type="file" :accept="AVATAR_ACCEPT" hidden data-testid="avatar-input" @change="onPick" />
    <button v-if="editable && path" class="linkish" type="button" :disabled="busy" @click="remove">Remove photo</button>
    <small v-if="error" class="error" role="alert">{{ error }}</small>
  </div>
</template>

<style scoped>
.avatar-upload { display: grid; justify-items: center; gap: 6px; }
.pick { position: relative; background: none; border: 0; padding: 0; border-radius: 50%; cursor: pointer; }
.overlay {
  position: absolute; inset: 0; border-radius: 50%; display: grid; place-items: center; align-content: center; gap: 2px;
  font-size: 10px; font-weight: 600; color: #fff; background: rgba(20, 51, 41, 0.62); opacity: 0; transition: opacity 0.18s var(--ease);
}
.pick:hover .overlay, .pick:focus-visible .overlay { opacity: 1; }
.linkish { background: none; border: 0; color: var(--muted); font-size: 11px; text-decoration: underline; text-underline-offset: 2px; padding: 0; }
.linkish:hover { color: var(--red); }
.error { color: var(--red); font-size: 11px; max-width: 200px; text-align: center; }
</style>
