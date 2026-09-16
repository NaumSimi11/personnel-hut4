<script setup lang="ts">
import { ref } from 'vue'

/**
 * A password field with a show / hide toggle — people paste temporary
 * passwords and type long ones on phones, so let them check what they
 * entered. Used wherever a password is typed (sign in, set a password).
 * The toggle is a real button with a label for screen readers; the field
 * keeps its id so the page's <label for> still points at it.
 */
withDefaults(defineProps<{ id: string; modelValue: string; autocomplete?: string; required?: boolean }>(), {
  autocomplete: 'current-password',
  required: false,
})
defineEmits<{ 'update:modelValue': [value: string] }>()

const shown = ref(false)
</script>

<template>
  <div class="password-input">
    <input
      :id="id"
      :type="shown ? 'text' : 'password'"
      :value="modelValue"
      :autocomplete="autocomplete"
      :required="required"
      spellcheck="false"
      @input="$emit('update:modelValue', ($event.target as HTMLInputElement).value)"
    />
    <button
      class="toggle"
      type="button"
      :aria-label="shown ? 'Hide password' : 'Show password'"
      :aria-pressed="shown"
      :title="shown ? 'Hide password' : 'Show password'"
      data-testid="toggle-password"
      @click="shown = !shown"
    >
      <svg v-if="shown" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M3 3l18 18" />
        <path d="M10.6 10.6a2 2 0 0 0 2.8 2.8" />
        <path d="M9.9 5.1A10.9 10.9 0 0 1 12 5c5 0 9 4 10 7-.4 1.2-1.2 2.5-2.4 3.6M6.6 6.6C4.4 8 2.8 10 2 12c1 3 5 7 10 7 1.7 0 3.3-.4 4.7-1.2" />
      </svg>
      <svg v-else viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M2 12c1-3 5-7 10-7s9 4 10 7c-1 3-5 7-10 7S3 15 2 12z" />
        <circle cx="12" cy="12" r="3" />
      </svg>
    </button>
  </div>
</template>

<style scoped>
.password-input { position: relative; }
.password-input input { padding-right: 44px; }
.toggle {
  position: absolute;
  top: 50%;
  right: 4px;
  transform: translateY(-50%);
  display: inline-grid;
  place-items: center;
  width: 36px;
  height: 36px;
  padding: 0;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: var(--muted);
  cursor: pointer;
  transition: color 0.18s var(--ease), background 0.18s var(--ease);
}
.toggle:hover { color: var(--ink); background: #eef2ec; }
.toggle[aria-pressed='true'] { color: var(--green); }
</style>
