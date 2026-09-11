<script setup lang="ts">
import { computed } from 'vue'
import { JOB_STEPS, stepIndex, type StepId } from '@/lib/jobWorkspace'

/** The five-step hiring journey from the prototype, with the current step lit. */
const props = defineProps<{ current: StepId }>()
const currentIndex = computed(() => stepIndex(props.current))
</script>

<template>
  <ol class="stepper" aria-label="Hiring journey">
    <li
      v-for="(step, i) in JOB_STEPS"
      :key="step.id"
      class="step"
      :class="{ done: i < currentIndex, current: i === currentIndex }"
      :aria-current="i === currentIndex ? 'step' : undefined"
    >
      <span class="number" aria-hidden="true">{{ step.number }}</span>
      <span class="label">{{ step.label }}</span>
    </li>
  </ol>
</template>

<style scoped>
.stepper {
  display: flex;
  gap: 8px;
  list-style: none;
  margin: 0 0 22px;
  padding: 0;
  overflow-x: auto;
}
.step {
  flex: 1;
  min-width: 120px;
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 11px 13px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: #fff;
  color: var(--muted);
  font-size: 11px;
}
.number {
  display: grid;
  place-items: center;
  width: 24px;
  height: 24px;
  border-radius: 7px;
  background: #f0f1ef;
  font-size: 10px;
  font-weight: 650;
  flex-shrink: 0;
}
.step.done { color: var(--ink); }
.step.done .number { background: #edf5ed; color: #3e744e; }
.step.current { color: var(--ink); font-weight: 600; border-color: var(--green); }
.step.current .number { background: var(--green); color: #fff; }
</style>
