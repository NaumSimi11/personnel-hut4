<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { taskInput, type MyTask, type TaskPerson } from '@/lib/tasks'

/**
 * Write a task down, or change one (plan 057).
 *
 * Three fields and two pickers, in the order the thought arrives: what has to
 * happen, by when, whose it is, who else is on it. "For" only appears when
 * there is somebody else you may hand one to — most people may only give
 * themselves a task, and a picker with one entry is furniture.
 */
const props = defineProps<{
  /** Who the signed-in person may hand a task to, themselves included. */
  assignable: TaskPerson[]
  /** Colleagues who may be connected to it. */
  connectable: TaskPerson[]
  /** The signed-in person, so "me" can be named and preselected. */
  meId: string
}>()

const emit = defineEmits<{ confirmed: [payload: { id?: string; person_id?: string; title: string; detail?: string; due_date?: string; with_ids: string[] }] }>()

const dialog = ref<HTMLDialogElement | null>(null)
const editing = ref<MyTask | null>(null)
const title = ref('')
const detail = ref('')
const dueDate = ref('')
const personId = ref('')
const withIds = ref<string[]>([])
const error = ref<string | null>(null)

const isEdit = computed(() => editing.value !== null)
// A task never changes hands, so the owner is fixed once it exists.
const mayChooseOwner = computed(() => !isEdit.value && props.assignable.length > 1)
const ownerName = computed(
  () => props.assignable.find((p) => p.id === personId.value)?.full_name ?? editing.value?.person_name ?? 'you',
)

function open(task: MyTask | null): void {
  editing.value = task
  title.value = task?.title ?? ''
  detail.value = task?.detail ?? ''
  dueDate.value = task?.due_date ?? ''
  personId.value = task?.person_id ?? props.meId
  withIds.value = task?.with_people.map((p) => p.id) ?? []
  error.value = null
  dialog.value?.showModal()
}
defineExpose({ open })

function toggleWith(id: string, on: boolean): void {
  withIds.value = on ? [...new Set([...withIds.value, id])] : withIds.value.filter((x) => x !== id)
}

// Hand the task to somebody who was on it as a guest and they stop being one:
// the database refuses an owner who is also connected, and leaving the id in
// would refuse the save with no chip on screen to explain it.
watch(personId, (now) => {
  withIds.value = withIds.value.filter((id) => id !== now)
})

function submit(): void {
  const parsed = taskInput.safeParse({
    ...(editing.value ? { id: editing.value.id } : {}),
    ...(mayChooseOwner.value ? { person_id: personId.value } : {}),
    title: title.value,
    detail: detail.value || undefined,
    due_date: dueDate.value || undefined,
    with_ids: withIds.value,
  })
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  dialog.value?.close()
  emit('confirmed', { ...parsed.data, with_ids: parsed.data.with_ids ?? [] })
}

/**
 * Whom the "With" list may show: the colleagues this person may connect, plus
 * anybody already on the task. The second half matters — a task set by HR may
 * carry somebody the owner could not have added themselves, and without a
 * chip they could never take them off. The owner is never a guest.
 */
const guests = computed<TaskPerson[]>(() => {
  const byId = new Map<string, TaskPerson>()
  for (const p of props.connectable) byId.set(p.id, p)
  for (const p of editing.value?.with_people ?? []) byId.set(p.id, p)
  byId.delete(personId.value)
  return [...byId.values()].sort((a, b) => a.full_name.localeCompare(b.full_name))
})
</script>

<template>
  <dialog ref="dialog" class="task-dialog" aria-labelledby="task-dialog-title" data-testid="task-dialog">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">{{ isEdit ? 'Change a task' : 'New task' }}</div>
      <h2 id="task-dialog-title">{{ isEdit ? 'Change this task.' : 'What has to happen?' }}</h2>

      <div class="field">
        <label for="task-title">Task</label>
        <input id="task-title" v-model="title" type="text" maxlength="200" data-testid="task-title" placeholder="Book the meeting room" />
      </div>

      <div class="pair">
        <div class="field">
          <label for="task-due">Due (optional)</label>
          <input id="task-due" v-model="dueDate" type="date" data-testid="task-due" />
        </div>
        <div v-if="mayChooseOwner" class="field">
          <label for="task-person">For</label>
          <select id="task-person" v-model="personId" data-testid="task-person">
            <option v-for="p in assignable" :key="p.id" :value="p.id">
              {{ p.id === meId ? `${p.full_name} (me)` : p.full_name }}
            </option>
          </select>
        </div>
      </div>

      <div class="field">
        <label for="task-detail">Note (optional)</label>
        <textarea id="task-detail" v-model="detail" rows="3" maxlength="2000" data-testid="task-detail"></textarea>
      </div>

      <fieldset v-if="guests.length" class="field people">
        <legend>With</legend>
        <p class="hint">
          They see it, they are told, and they can tick it off. It stays
          {{ personId === meId ? 'yours' : `${ownerName}'s` }} to change or delete.
        </p>
        <div class="chips">
          <label v-for="p in guests" :key="p.id" class="chip" :class="{ on: withIds.includes(p.id) }">
            <input
              type="checkbox"
              :checked="withIds.includes(p.id)"
              :data-testid="`task-with-${p.id}`"
              @change="toggleWith(p.id, ($event.target as HTMLInputElement).checked)"
            />
            {{ p.full_name }}
          </label>
        </div>
      </fieldset>

      <p v-if="error" class="error-note" role="alert" data-testid="task-dialog-error">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" data-testid="task-save">{{ isEdit ? 'Save' : 'Add task' }}</button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.task-dialog {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(520px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.task-dialog::backdrop { background: #18372d70; }
.body { padding: 26px 28px; max-height: min(80vh, 640px); overflow: auto; }
h2 { font-size: 19px; margin: 10px 0 16px; }
.field { margin-bottom: 14px; }
.field label, legend { display: block; font-size: 11px; color: var(--muted); margin-bottom: 5px; padding: 0; }
.field input[type='text'],
.field input[type='date'],
.field select,
.field textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 10px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  border-radius: 8px;
}
.field textarea { resize: vertical; }
.pair { display: grid; grid-template-columns: 1fr 1fr; gap: 0 14px; }
@media (max-width: 520px) { .pair { grid-template-columns: 1fr; } }
.people { border: 0; margin: 0 0 14px; padding: 0; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin: 0 0 9px; }
.chips { display: flex; flex-wrap: wrap; gap: 7px; }
.chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  border: 1px solid var(--line);
  border-radius: 999px;
  padding: 6px 12px;
  cursor: pointer;
  margin: 0;
}
.chip.on { border-color: var(--green); color: var(--green); font-weight: 550; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 6px; }
</style>
