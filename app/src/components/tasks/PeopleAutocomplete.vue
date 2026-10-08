<script setup lang="ts">
import { computed, ref } from 'vue'
import { suggestGuests, type TaskPerson } from '@/lib/tasks'

/**
 * Pick people by typing (2026-10-08, HR: "an autocomplete to search and
 * select people"). The chosen sit as chips with a remove button; the box
 * suggests up to eight matches as you type — arrows to move, Enter to add,
 * Escape to close the list (not the dialog), Backspace on an empty box to
 * take off the last chip. A click on a suggestion lands before the box blurs.
 */
const props = withDefaults(defineProps<{ people: TaskPerson[]; modelValue: string[]; placeholder?: string }>(), {
  placeholder: 'Add a person…',
})
const emit = defineEmits<{ 'update:modelValue': [ids: string[]] }>()

const uid = `people-${Math.random().toString(36).slice(2, 9)}`
const query = ref('')
const active = ref(0)
const focused = ref(false)

const chosen = computed(() =>
  props.modelValue
    .map((id) => props.people.find((p) => p.id === id))
    .filter((p): p is TaskPerson => Boolean(p)),
)
const suggestions = computed(() => suggestGuests(props.people, query.value, props.modelValue))
const listOpen = computed(() => focused.value && query.value.trim().length > 0)

function pick(p: TaskPerson): void {
  emit('update:modelValue', [...props.modelValue, p.id])
  query.value = ''
  active.value = 0
}

function remove(id: string): void {
  emit('update:modelValue', props.modelValue.filter((x) => x !== id))
}

function onInput(value: string): void {
  query.value = value
  active.value = 0
}

function onKeydown(e: KeyboardEvent): void {
  const n = suggestions.value.length
  if (e.key === 'ArrowDown' && n) {
    e.preventDefault()
    active.value = (active.value + 1) % n
  } else if (e.key === 'ArrowUp' && n) {
    e.preventDefault()
    active.value = (active.value - 1 + n) % n
  } else if (e.key === 'Enter' && query.value.trim()) {
    // Typing is never a submit: Enter adds the highlighted match, or nothing.
    e.preventDefault()
    const p = suggestions.value[active.value]
    if (p) pick(p)
  } else if (e.key === 'Escape' && query.value) {
    e.preventDefault()
    e.stopPropagation()
    query.value = ''
  } else if (e.key === 'Backspace' && !query.value && props.modelValue.length) {
    remove(props.modelValue[props.modelValue.length - 1] as string)
  }
}
</script>

<template>
  <div class="people-picker">
    <ul v-if="chosen.length" class="chosen" aria-label="On this task">
      <li v-for="p in chosen" :key="p.id" class="chip" :data-testid="`task-with-${p.id}`">
        <span>{{ p.full_name }}</span>
        <button type="button" class="remove" :aria-label="`Remove ${p.full_name}`" :data-testid="`task-with-remove-${p.id}`" @click="remove(p.id)">
          ×
        </button>
      </li>
    </ul>
    <div class="box">
      <input
        :value="query"
        type="text"
        role="combobox"
        autocomplete="off"
        :aria-expanded="listOpen"
        :aria-controls="`${uid}-list`"
        :aria-activedescendant="listOpen && suggestions.length ? `${uid}-opt-${active}` : undefined"
        aria-label="Add a person"
        :placeholder="placeholder"
        data-testid="task-people-search"
        @input="onInput(($event.target as HTMLInputElement).value)"
        @keydown="onKeydown"
        @focus="focused = true"
        @blur="focused = false"
      />
      <ul v-if="listOpen" :id="`${uid}-list`" class="suggestions" role="listbox">
        <li
          v-for="(p, i) in suggestions"
          :id="`${uid}-opt-${i}`"
          :key="p.id"
          role="option"
          :aria-selected="i === active"
          class="option"
          :class="{ active: i === active }"
          :data-testid="`task-suggest-${p.id}`"
          @mousedown.prevent="pick(p)"
          @mouseenter="active = i"
        >
          {{ p.full_name }}
        </li>
        <li v-if="!suggestions.length" class="none">Nobody matches “{{ query.trim() }}”.</li>
      </ul>
    </div>
  </div>
</template>

<style scoped>
.chosen { list-style: none; display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 8px; padding: 0; }
.chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  max-width: 100%;
  font-size: 12px;
  font-weight: 550;
  color: var(--green);
  background: var(--green-soft);
  border: 1px solid var(--green);
  border-radius: 999px;
  padding: 4px 6px 4px 11px;
}
.chip span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.remove { background: none; border: 0; padding: 0 5px; font-size: 15px; line-height: 1; color: inherit; cursor: pointer; border-radius: 999px; }
.remove:hover { background: #ffffff99; }
.box { position: relative; }
.box input {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 10px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  border-radius: 8px;
}
.suggestions {
  position: absolute;
  z-index: 5;
  left: 0;
  right: 0;
  top: calc(100% + 4px);
  list-style: none;
  margin: 0;
  padding: 4px;
  background: #fff;
  border: 1px solid var(--line);
  border-radius: 9px;
  box-shadow: 0 12px 30px #122f3024;
  max-height: 240px;
  overflow-y: auto;
}
.option { padding: 8px 10px; font-size: 12px; border-radius: 6px; cursor: pointer; }
.option.active { background: var(--green-soft); color: var(--green); }
.none { padding: 8px 10px; font-size: 12px; color: var(--muted); }
</style>
