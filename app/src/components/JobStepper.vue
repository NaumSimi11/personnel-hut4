<script setup lang="ts">
import { computed } from 'vue'
import { JOURNEY_STEPS, journeyStepIndex, type JourneyStep, type JourneyStepId } from '@/lib/journey'

/**
 * The journey strip, with the current step lit.
 *
 * It defaults to the whole arc — hiring through to the person's first day — so
 * the job page and the onboarding plan page show one continuous journey. Pass
 * `steps` to show a shorter stretch of it.
 */
type StripStep = { id: string; number: string; label: string }

const props = withDefaults(
  defineProps<{ current: string; steps?: readonly StripStep[]; label?: string; compact?: boolean }>(),
  { steps: () => JOURNEY_STEPS as readonly StripStep[], label: 'Hiring journey', compact: false },
)
const currentIndex = computed(() => {
  const own = props.steps.findIndex((s) => s.id === props.current)
  return own === -1 ? journeyStepIndex(props.current as JourneyStepId) : own
})
</script>

<template>
  <ol class="stepper" :class="{ compact }" :aria-label="label">
    <li
      v-for="(step, i) in steps"
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
  font-size: 11px;
  font-weight: 650;
  flex-shrink: 0;
}
.stepper.compact { margin: 0 24px 16px; gap: 6px; }
.stepper.compact .step { min-width: 92px; padding: 7px 10px; font-size: 10px; }
.stepper.compact .number { width: 19px; height: 19px; font-size: 10px; }
.step.done { color: var(--ink); }
.step.done .number { background: #edf5ed; color: #3e744e; }
.step.current { color: var(--ink); font-weight: 600; border-color: var(--green); }
.step.current .number { background: var(--green); color: #fff; }
</style>
