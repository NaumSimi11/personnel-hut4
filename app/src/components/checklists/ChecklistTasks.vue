<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { todayDb } from '@/lib/compensation'
import type { Database } from '@/types/database'
import {
  OWNER_ROLES,
  groupByPhase,
  messageForChecklist,
  ownerLabel,
  progress,
  type ChecklistKind,
  type ChecklistTask,
  type Phase,
} from '@/lib/checklists'

/**
 * One person's checklist as a checkbox list (plan 047): tick = done, untick
 * = reopen; a small menu for Skip / Block / Unblock (dialogs, never
 * prompts); an Add task line for the one-off item. Used by the plan page
 * and inline on the Onboarding / Offboarding queues. RLS decides who may
 * tick (tasks.complete / tasks.assign in the company, or the task's owner);
 * add_plan_task needs tasks.assign.
 */
const props = defineProps<{
  planId: string
  companyId: string
  kind: ChecklistKind
  tasks: ChecklistTask[]
  phases: Phase[]
  /** False once the plan is closed: only Reopen on a done line stays. */
  active: boolean
  compact?: boolean
}>()
const emit = defineEmits<{ changed: [] }>()

const auth = useAuthStore()
const dialogs = useDialogStore()
const busyId = ref<string | null>(null)
const error = ref<string | null>(null)
const adding = ref(false)
const newTask = ref({ title: '', ownerRole: 'hr', dueDate: '' })
const addBusy = ref(false)

const grouped = computed(() => groupByPhase(props.phases, props.tasks))
const bar = computed(() => progress(props.tasks))
const canAdd = computed(() => props.active && auth.can(props.companyId, 'tasks.assign'))
const criticalWord = computed(() => (props.kind === 'offboarding' ? 'Blocker' : 'Required before start'))

type TaskPatch = Database['public']['Tables']['plan_tasks']['Update']

async function patch(task: ChecklistTask, fields: TaskPatch): Promise<boolean> {
  error.value = null
  busyId.value = task.id
  const { data, error: err } = await supabase.from('plan_tasks').update(fields).eq('id', task.id).select('id').maybeSingle()
  busyId.value = null
  if (err || !data) {
    error.value = err ? messageForChecklist(err) : 'You do not have permission to change this line.'
    return false
  }
  emit('changed')
  return true
}

/** The box follows the record: a refused tick snaps it back. */
async function toggle(task: ChecklistTask, input: HTMLInputElement): Promise<void> {
  const checked = input.checked
  const ok = checked
    ? await patch(task, { status: 'done', done_by: auth.personId, done_at: new Date().toISOString() })
    : await patch(task, { status: 'open', done_by: null, done_at: null })
  if (!ok) input.checked = !checked
}

async function skip(task: ChecklistTask): Promise<void> {
  const answer = await dialogs.askReason({
    title: `Skip "${task.title}"?`,
    hint: 'The line closes without being done; the reason stays on the checklist.',
    confirmLabel: 'Skip',
  })
  if (!answer) return
  await patch(task, { status: 'skipped', skip_reason: answer.reason })
}

async function block(task: ChecklistTask): Promise<void> {
  const answer = await dialogs.askReason({
    title: `What blocks "${task.title}"?`,
    hint: 'The reason shows on the line until it is unblocked or done.',
    confirmLabel: 'Mark blocked',
  })
  if (!answer) return
  await patch(task, { status: 'blocked', blocked_reason: answer.reason })
}

function unblock(task: ChecklistTask): void {
  void patch(task, { status: 'open', blocked_reason: null })
}

function reopenSkipped(task: ChecklistTask): void {
  void patch(task, { status: 'open', skip_reason: null })
}

async function addTask(): Promise<void> {
  error.value = null
  if (newTask.value.title.trim().length < 2) {
    error.value = 'Enter what has to be done.'
    return
  }
  addBusy.value = true
  const { error: err } = await supabase.rpc('add_plan_task', {
    p_plan_id: props.planId,
    p_title: newTask.value.title.trim(),
    p_owner_role: newTask.value.ownerRole,
    p_due_date: newTask.value.dueDate || undefined,
    p_critical: false,
  })
  addBusy.value = false
  if (err) {
    error.value = messageForChecklist(err)
    return
  }
  newTask.value = { title: '', ownerRole: 'hr', dueDate: '' }
  adding.value = false
  emit('changed')
}

function dueClass(task: ChecklistTask): string {
  if (task.status === 'done' || task.status === 'skipped' || !task.due_date) return ''
  return task.due_date < todayDb() ? 'overdue' : ''
}
</script>

<template>
  <div class="checklist" :class="{ compact }" :data-testid="`checklist-${planId}`">
    <div class="progress" role="progressbar" :aria-valuenow="bar.percent" aria-valuemin="0" aria-valuemax="100" :aria-label="`${bar.closed} of ${bar.total} done`">
      <div class="bar"><span :style="{ width: `${bar.percent}%` }"></span></div>
      <small data-testid="progress-label">{{ bar.closed }} of {{ bar.total }} done<template v-if="bar.criticalOpen"> · {{ bar.criticalOpen }} {{ kind === 'offboarding' ? (bar.criticalOpen === 1 ? 'blocker' : 'blockers') : 'required still open' }}</template></small>
    </div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>

    <div v-for="phase in grouped" :key="phase.key" class="phase">
      <h3 v-if="!compact" class="phase-heading">{{ phase.label }}</h3>
      <div v-for="task in phase.tasks" :key="task.id" class="line task-row" :class="[task.status, dueClass(task)]" :data-testid="`task-${task.id}`">
        <label class="tick">
          <input
            type="checkbox"
            :checked="task.status === 'done'"
            :disabled="busyId === task.id || (!active && task.status !== 'done') || task.status === 'skipped'"
            :aria-label="`${task.title} done`"
            @change="toggle(task, $event.target as HTMLInputElement)"
          />
        </label>
        <div class="text">
          <strong>{{ task.title }}</strong>
          <small>
            {{ ownerLabel(task.owner_role) }}<template v-if="task.owner?.full_name"> · {{ task.owner.full_name }}</template>
            <template v-if="task.due_date"> · due {{ task.due_date }}</template>
            <template v-if="task.critical"> · {{ criticalWord }}</template>
          </small>
          <p v-if="task.status === 'blocked' && task.blocked_reason" class="reason">Blocked: {{ task.blocked_reason }}</p>
          <p v-if="task.status === 'skipped'" class="reason">Skipped<template v-if="task.skip_reason">: {{ task.skip_reason }}</template></p>
        </div>
        <span class="badge" :class="task.status === 'done' ? 'green' : task.status === 'blocked' ? 'amber' : task.status === 'open' ? 'blue' : ''">{{ task.status }}</span>
        <details v-if="active && task.status !== 'done'" class="menu">
          <summary aria-label="More actions">···</summary>
          <div class="menu-items">
            <button v-if="task.status === 'open'" type="button" class="menu-item" @click="skip(task)">Skip</button>
            <button v-if="task.status === 'open'" type="button" class="menu-item" @click="block(task)">Block</button>
            <button v-if="task.status === 'blocked'" type="button" class="menu-item" @click="unblock(task)">Unblock</button>
            <button v-if="task.status === 'skipped'" type="button" class="menu-item" @click="reopenSkipped(task)">Put back</button>
          </div>
        </details>
      </div>
    </div>

    <div v-if="canAdd" class="add-line">
      <button v-if="!adding" type="button" class="link-button" data-testid="add-task" @click="adding = true">+ Add task</button>
      <form v-else class="add-form" novalidate @submit.prevent="addTask">
        <input v-model="newTask.title" :id="`new-task-${planId}`" maxlength="160" placeholder="What has to be done" aria-label="New task" />
        <select v-model="newTask.ownerRole" aria-label="Owner">
          <option v-for="o in OWNER_ROLES" :key="o.key" :value="o.key">{{ o.label }}</option>
        </select>
        <input v-model="newTask.dueDate" type="date" aria-label="Due date" />
        <button class="button small-btn" type="submit" :disabled="addBusy">Add</button>
        <button class="button secondary small-btn" type="button" @click="adding = false">Cancel</button>
      </form>
    </div>
  </div>
</template>

<style scoped>
.progress { padding: 12px 24px 4px; }
.compact .progress { padding: 8px 0 4px; }
.bar { height: 6px; border-radius: 999px; background: #e8ede6; overflow: hidden; }
.bar span { display: block; height: 100%; background: linear-gradient(90deg, var(--green-bright), var(--green)); transition: width 200ms ease; }
.progress small { display: block; margin-top: 6px; font-size: 11px; color: var(--muted); }
.phase-heading { font-size: 11px; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin: 14px 24px 0; }
.line { display: flex; align-items: flex-start; gap: 12px; padding: 12px 24px; border-top: 1px solid #edf0eb; }
.compact .line { padding: 10px 0; }
.line.done .text strong { text-decoration: line-through; color: var(--muted); }
.line.skipped .text strong { color: var(--muted); }
.line.overdue .text small { color: var(--red); }
.tick { padding-top: 2px; }
.tick input { width: 18px; height: 18px; accent-color: var(--green); cursor: pointer; }
.tick input:disabled { cursor: default; }
.text { flex: 1; min-width: 0; }
.text strong { display: block; font-size: 12px; font-weight: 550; }
.text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.reason { margin: 4px 0 0; font-size: 11px; color: var(--amber); }
.menu { position: relative; }
.menu summary { list-style: none; cursor: pointer; font-size: 14px; letter-spacing: 1px; padding: 2px 8px; border-radius: 6px; color: var(--muted); }
.menu summary::-webkit-details-marker { display: none; }
.menu summary:hover { background: #f1f4ef; color: var(--ink); }
.menu-items { position: absolute; right: 0; top: 100%; z-index: 2; background: #fff; border: 1px solid var(--line); border-radius: 9px; box-shadow: var(--shadow-sm); min-width: 120px; padding: 4px; }
.menu-item { display: block; width: 100%; text-align: left; border: 0; background: none; padding: 7px 10px; font-size: 12px; cursor: pointer; border-radius: 6px; }
.menu-item:hover { background: #f1f4ef; }
.add-line { padding: 12px 24px 14px; border-top: 1px solid #edf0eb; }
.compact .add-line { padding: 10px 0; }
.link-button { border: 0; background: none; color: var(--green); font-size: 12px; padding: 0; cursor: pointer; font-weight: 600; }
.add-form { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.add-form input, .add-form select { border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; background: #fff; }
.add-form input[type='text'], .add-form input:not([type]) { flex: 1; min-width: 200px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
