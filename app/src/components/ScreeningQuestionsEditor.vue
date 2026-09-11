<script setup lang="ts">
import { QUESTION_KINDS, newQuestion, type ScreeningQuestion } from '@/lib/jobWorkspace'

/**
 * Edit a job's screening questions (jobs.screening_questions). Immutable
 * updates: every change emits a new array. Options for choice questions are
 * one per line in a textarea — simple to type, simple to validate.
 */
const props = defineProps<{ modelValue: ScreeningQuestion[]; disabled?: boolean }>()
const emit = defineEmits<{ 'update:modelValue': [questions: ScreeningQuestion[]] }>()

const KIND_LABELS: Record<(typeof QUESTION_KINDS)[number], string> = {
  text: 'Free text',
  yes_no: 'Yes / no',
  choice: 'Choice',
}

function update(index: number, patch: Partial<ScreeningQuestion>): void {
  emit(
    'update:modelValue',
    props.modelValue.map((q, i) => (i === index ? { ...q, ...patch } : q)),
  )
}

function add(): void {
  emit('update:modelValue', [...props.modelValue, newQuestion()])
}

function remove(index: number): void {
  emit(
    'update:modelValue',
    props.modelValue.filter((_, i) => i !== index),
  )
}

function optionsText(q: ScreeningQuestion): string {
  return (q.options ?? []).join('\n')
}

function setOptions(index: number, raw: string): void {
  update(index, { options: raw.split('\n').map((o) => o.trim()).filter(Boolean) })
}
</script>

<template>
  <div class="questions">
    <p v-if="!modelValue.length" class="empty-note">
      No screening questions yet. Candidates answer these when they apply; answers show on their application.
    </p>
    <div v-for="(q, i) in modelValue" :key="q.id" class="question-row">
      <div class="question-main">
        <input
          class="question-prompt"
          :value="q.prompt"
          :disabled="disabled"
          maxlength="300"
          placeholder="Question"
          :aria-label="`Question ${i + 1}`"
          @input="update(i, { prompt: ($event.target as HTMLInputElement).value })"
        />
        <textarea
          v-if="q.kind === 'choice'"
          class="question-options"
          rows="3"
          :value="optionsText(q)"
          :disabled="disabled"
          placeholder="One option per line"
          :aria-label="`Options for question ${i + 1}`"
          @input="setOptions(i, ($event.target as HTMLTextAreaElement).value)"
        ></textarea>
      </div>
      <select
        class="question-kind"
        :value="q.kind"
        :disabled="disabled"
        :aria-label="`Answer type for question ${i + 1}`"
        @change="update(i, { kind: ($event.target as HTMLSelectElement).value as ScreeningQuestion['kind'] })"
      >
        <option v-for="kind in QUESTION_KINDS" :key="kind" :value="kind">{{ KIND_LABELS[kind] }}</option>
      </select>
      <label class="required">
        <input type="checkbox" :checked="q.required" :disabled="disabled" @change="update(i, { required: ($event.target as HTMLInputElement).checked })" />
        Required
      </label>
      <button class="button secondary small-btn" type="button" :disabled="disabled" @click="remove(i)">
        Remove
      </button>
    </div>
    <button class="button secondary small-btn" type="button" :disabled="disabled" @click="add">
      Add question
    </button>
  </div>
</template>

<style scoped>
.questions { display: grid; gap: 10px; }
.empty-note { margin: 0; font-size: 11px; color: var(--muted); line-height: 1.6; }
.question-row {
  display: flex;
  align-items: flex-start;
  gap: 9px;
  flex-wrap: wrap;
  padding: 12px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: #fafbf9;
}
.question-main { flex: 1; min-width: 240px; display: grid; gap: 8px; }
.question-prompt, .question-options, .question-kind {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 9px 11px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
}
.question-kind { width: auto; }
.question-options { resize: vertical; }
.required { display: flex; align-items: center; gap: 6px; font-size: 11px; padding-top: 9px; }
.small-btn { font-size: 11px; padding: 7px 11px; align-self: flex-start; }
</style>
