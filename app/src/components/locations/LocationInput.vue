<script setup lang="ts">
/**
 * A typed location (25 Nov): any place, with the company's earlier ones
 * suggested as you type. Skopje, Struga, Vilnius, Lithuania…
 */
const props = defineProps<{ id: string; suggestions: ReadonlyArray<string>; disabled?: boolean; ariaLabel?: string }>()
const model = defineModel<string>({ required: true })
const emit = defineEmits<{ commit: [] }>()
</script>

<template>
  <span class="location-input">
    <input
      :id="props.id"
      v-model="model"
      type="text"
      maxlength="80"
      autocomplete="off"
      :list="`${props.id}-places`"
      :disabled="props.disabled"
      :aria-label="props.ariaLabel"
      placeholder="e.g. Skopje, Struga, Vilnius"
      @keydown.enter.prevent="emit('commit')"
    />
    <datalist :id="`${props.id}-places`">
      <option v-for="s in props.suggestions" :key="s" :value="s" />
    </datalist>
  </span>
</template>

<style scoped>
.location-input input { width: 100%; border: 1px solid #dce3d7; padding: 7px 10px; font-size: 12px; background: #fff; }
</style>
