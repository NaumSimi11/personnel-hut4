<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import TaskDialog from '@/components/tasks/TaskDialog.vue'
import {
  dueLabel,
  dueTone,
  friendlyTaskError,
  openCount,
  orderTasks,
  ownerLine,
  readMyTasks,
  withLine,
  EMPTY_TASKS,
  type MyTask,
  type MyTasks,
  type TaskPerson,
} from '@/lib/tasks'

/**
 * My tasks (plan 057): the things I have to do that are not a checklist line
 * — written down by me, or handed to me by my manager or HR — and the ones I
 * have handed out.
 *
 * A connected colleague's task sits in the same list as my own, named as
 * theirs, because for the person looking at it the question is the same:
 * what is left. The list only ever holds what the database let me see.
 */
const auth = useAuthStore()
const dialogs = useDialogStore()

const tasks = ref<MyTasks>(EMPTY_TASKS)
const assignable = ref<TaskPerson[]>([])
const connectable = ref<TaskPerson[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const busyId = ref<string | null>(null)
const showDone = ref(false)
const taskDialog = ref<InstanceType<typeof TaskDialog> | null>(null)

const mine = computed(() => orderTasks(tasks.value.mine).filter((t) => showDone.value || t.status === 'open'))
const open = computed(() => openCount(tasks.value.mine))
const handedOut = computed(() => orderTasks(tasks.value.set_by_me).filter((t) => t.status === 'open'))

function mayEdit(task: MyTask): boolean {
  // The same rule the database holds: the owner and whoever set it.
  return task.person_id === auth.personId || task.created_by === auth.personId
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [tasksRes, peopleRes] = await Promise.all([supabase.rpc('my_tasks'), supabase.rpc('task_candidates')])
  loading.value = false
  if (tasksRes.error) {
    error.value = 'Could not load your tasks.'
    console.error('My tasks load failed:', tasksRes.error.message)
    return
  }
  tasks.value = readMyTasks(tasksRes.data)
  if (peopleRes.error) {
    // The list still reads; only writing needs the pickers.
    console.error('Task candidates load failed:', peopleRes.error.message)
    return
  }
  const people = (peopleRes.data ?? {}) as { assignable?: TaskPerson[]; connectable?: TaskPerson[] }
  assignable.value = people.assignable ?? []
  connectable.value = people.connectable ?? []
}

function add(): void {
  error.value = null
  taskDialog.value?.open(null)
}

function edit(task: MyTask): void {
  error.value = null
  taskDialog.value?.open(task)
}

type SavePayload = {
  id?: string
  person_id?: string
  title: string
  detail?: string
  due_date?: string
  with_ids: string[]
}

async function save(payload: SavePayload): Promise<void> {
  error.value = null
  busyId.value = payload.id ?? 'new'
  const { error: err } = await supabase.rpc('save_task', { p: payload as never })
  busyId.value = null
  if (err) {
    error.value = friendlyTaskError(err.message)
    return
  }
  await load()
}

async function setDone(task: MyTask, done: boolean): Promise<void> {
  error.value = null
  busyId.value = task.id
  const { error: err } = await supabase.rpc('set_task_done', { p_task_id: task.id, p_done: done })
  busyId.value = null
  if (err) {
    error.value = friendlyTaskError(err.message)
    return
  }
  await load()
}

async function remove(task: MyTask): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Delete "${task.title}"?`,
    hint: task.with_people.length
      ? 'It goes from your list and from everyone connected to it. This cannot be undone.'
      : 'This cannot be undone.',
    confirmLabel: 'Delete task',
    danger: true,
  })
  if (!ok) return
  error.value = null
  busyId.value = task.id
  const { error: err } = await supabase.rpc('delete_task', { p_task_id: task.id })
  busyId.value = null
  if (err) {
    error.value = friendlyTaskError(err.message)
    return
  }
  await load()
}

onMounted(load)
</script>

<template>
  <div class="card" data-testid="my-tasks-card">
    <div class="card-head">
      <div>
        <h2>My tasks</h2>
        <p>
          <template v-if="open">{{ open }} to do{{ tasks.mine.length > open ? ` · ${tasks.mine.length - open} done` : '' }}</template>
          <template v-else>Anything you write down here, and anything handed to you.</template>
        </p>
      </div>
      <div class="head-actions">
        <button
          v-if="tasks.mine.length > open"
          class="button secondary small-btn"
          type="button"
          data-testid="tasks-toggle-done"
          @click="showDone = !showDone"
        >
          {{ showDone ? 'Hide done' : 'Show done' }}
        </button>
        <button class="button small-btn" type="button" data-testid="task-add" @click="add">Add task</button>
      </div>
    </div>

    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px" data-testid="tasks-error">{{ error }}</p>
    <div v-if="loading" class="empty">Loading your tasks…</div>
    <div v-else-if="!mine.length" class="empty" data-testid="tasks-empty">
      Nothing on your list. Add what you have to remember, and rope in whoever is doing it with you.
    </div>
    <ul v-else class="rows">
      <li v-for="t in mine" :key="t.id" class="row" :class="{ done: t.status === 'done' }" :data-testid="`task-${t.id}`">
        <label class="tick">
          <input
            type="checkbox"
            :checked="t.status === 'done'"
            :disabled="busyId === t.id"
            :aria-label="`Tick off ${t.title}`"
            :data-testid="`task-tick-${t.id}`"
            @change="setDone(t, ($event.target as HTMLInputElement).checked)"
          />
        </label>
        <div class="what">
          <strong>{{ t.title }}</strong>
          <p v-if="t.detail" class="detail">{{ t.detail }}</p>
          <p class="meta">
            <span v-if="dueLabel(t)" class="due" :class="dueTone(t)">{{ dueLabel(t) }}</span>
            <span v-if="ownerLine(t)" class="badge">{{ ownerLine(t) }}</span>
            <span v-else-if="t.created_by !== t.person_id">from {{ t.created_by_name }}</span>
            <span v-if="withLine(t)">{{ withLine(t) }}</span>
            <span v-if="t.status === 'done' && t.done_by_name">done by {{ t.done_by_name }}</span>
          </p>
        </div>
        <span v-if="mayEdit(t)" class="row-actions">
          <button class="link-btn" type="button" :disabled="busyId === t.id" :data-testid="`task-edit-${t.id}`" @click="edit(t)">Change</button>
          <button class="link-btn danger" type="button" :disabled="busyId === t.id" :data-testid="`task-delete-${t.id}`" @click="remove(t)">Delete</button>
        </span>
      </li>
    </ul>

    <div v-if="handedOut.length" class="handed" data-testid="tasks-handed-out">
      <h3>Waiting on other people</h3>
      <ul class="rows">
        <li v-for="t in handedOut" :key="t.id" class="row quiet">
          <div class="what">
            <strong>{{ t.title }}</strong>
            <p class="meta">
              <span>{{ t.person_name }}</span>
              <span v-if="dueLabel(t)" class="due" :class="dueTone(t)">{{ dueLabel(t) }}</span>
            </p>
          </div>
        </li>
      </ul>
    </div>

    <TaskDialog ref="taskDialog" :assignable="assignable" :connectable="connectable" :me-id="auth.personId ?? ''" @confirmed="save" />
  </div>
</template>

<style scoped>
.head-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.rows { list-style: none; margin: 0; padding: 0; }
.row { display: flex; gap: 12px; align-items: flex-start; padding: 13px 24px; border-bottom: 1px solid var(--line); }
.row:last-child { border-bottom: 0; }
.row.done .what strong { text-decoration: line-through; color: var(--muted); font-weight: 500; }
.tick { padding-top: 1px; }
.tick input { width: 16px; height: 16px; }
.what { flex: 1; min-width: 0; }
.what strong { font-size: 13px; font-weight: 600; display: block; }
.detail { font-size: 12px; color: var(--muted); margin: 3px 0 0; line-height: 1.5; white-space: pre-wrap; }
.meta { display: flex; flex-wrap: wrap; gap: 4px 12px; font-size: 11px; color: var(--muted); margin: 5px 0 0; }
.due.overdue { color: var(--red); font-weight: 600; }
.due.today { color: var(--green); font-weight: 600; }
.row-actions { display: flex; gap: 10px; flex-shrink: 0; }
.link-btn { background: none; border: 0; padding: 0; font: inherit; font-size: 11px; color: var(--muted); cursor: pointer; text-decoration: underline; }
.link-btn:hover:not(:disabled) { color: var(--ink); }
.link-btn.danger:hover:not(:disabled) { color: var(--red); }
.handed { border-top: 1px solid var(--line); }
.handed h3 { font-size: 11px; font-weight: 550; color: var(--muted); margin: 0; padding: 14px 24px 0; text-transform: none; }
.row.quiet { padding-top: 9px; padding-bottom: 9px; }
@media (max-width: 560px) {
  .row { flex-wrap: wrap; }
  .row-actions { width: 100%; padding-left: 28px; }
}
</style>
