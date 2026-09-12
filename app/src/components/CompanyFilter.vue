<script setup lang="ts">
/**
 * The one company dropdown for filtering a page or panel. Pass `all-label`
 * to offer "All companies" (value ''); without it the first company is
 * the only sensible default and the caller sets it. Form pickers that
 * choose where something is created are not filters and keep their own
 * selects.
 */
defineProps<{
  modelValue: string
  companies: { id: string; name: string }[]
  allLabel?: string
  label?: string
  id?: string
}>()
defineEmits<{ 'update:modelValue': [value: string] }>()
</script>

<template>
  <label class="company-filter" :class="{ labelled: label }">
    <span v-if="label" class="filter-label">{{ label }}</span>
    <select
      :id="id"
      :value="modelValue"
      :aria-label="label ? undefined : 'Company'"
      @change="$emit('update:modelValue', ($event.target as HTMLSelectElement).value)"
    >
      <option v-if="allLabel" value="">{{ allLabel }}</option>
      <option v-for="c in companies" :key="c.id" :value="c.id">{{ c.name }}</option>
    </select>
  </label>
</template>

<style scoped>
.company-filter { display: inline-grid; gap: 7px; }
.filter-label { font-size: 11px; font-weight: 550; color: #566653; }
select { border: 1px solid var(--line); background: #fff; padding: 8px 10px; font-size: 12px; color: var(--ink); min-width: 180px; }
</style>
