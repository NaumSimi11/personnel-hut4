<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { setApplicationStatus } from '@/lib/applicationStatus'
import { useHiringLookupsStore } from '@/stores/hiringLookups'
import { arrange, columnsFor, dropTarget, BOARD_COLUMNS, type BoardApplication, type BoardColumn, type OptionalStatus } from '@/lib/pipelineBoard'

/**
 * The pipeline board (0105; spec 9.8). One column per spec stage; drag a card
 * (or use its Move menu) and it gets that column's status through
 * set_application_status, which writes the timeline and refuses what may not
 * happen. Before the job opens, its optional stages can be switched off (3.3).
 */
type Card = BoardApplication & { candidate: { full_name: string } | null }

const props = defineProps<{
  jobId: string
  jobStatus: string
  skipStatuses: string[]
  canReview: boolean
  canEdit: boolean
}>()
const emit = defineEmits<{ changed: [] }>()

const BOARD_LIMIT = 500
const lookups = useHiringLookupsStore()
const cards = ref<Card[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const busyId = ref<string | null>(null)
const dragging = ref<string | null>(null)
const savingPipeline = ref(false)

const columns = computed(() => columnsFor(props.skipStatuses))
const arranged = computed(() => arrange(cards.value, props.skipStatuses))
const pipelineEditable = computed(() => props.canEdit && ['draft', 'ready'].includes(props.jobStatus))
const optionalColumns = computed(() => BOARD_COLUMNS.filter((c) => c.optional))
const labels = computed<Record<string, string>>(() => Object.fromEntries(lookups.statuses.map((s) => [s.key, s.label])))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  await lookups.ensure()
  const { data, error: err } = await supabase
    .from('applications')
    .select('id, stage_key, sub_status_key, in_play, candidate:candidates(full_name)')
    .eq('job_id', props.jobId)
    .or('in_play.eq.true,stage_key.eq.hired')
    .order('received_at', { ascending: false })
    .limit(BOARD_LIMIT)
  loading.value = false
  if (err) {
    console.error('Board load failed:', err.message)
    error.value = 'Could not load the board.'
    return
  }
  cards.value = (data ?? []) as unknown as Card[]
}

async function move(card: Card, column: BoardColumn): Promise<void> {
  const target = dropTarget(column, card)
  if (!target || !props.canReview) return
  busyId.value = card.id
  error.value = null
  const result = await setApplicationStatus([card.id], target, `Moved to ${column.label} on the board`)
  busyId.value = null
  if (result.error) {
    error.value = result.error
    return
  }
  await load()
  emit('changed')
}

function onDrop(column: BoardColumn): void {
  const card = cards.value.find((c) => c.id === dragging.value)
  dragging.value = null
  if (card) void move(card, column)
}

function onMoveSelect(card: Card, key: string): void {
  const column = columns.value.find((c) => c.key === key)
  if (column) void move(card, column)
}

async function toggleOptional(status: OptionalStatus, on: boolean): Promise<void> {
  const next = on ? props.skipStatuses.filter((s) => s !== status) : [...new Set([...props.skipStatuses, status])]
  await saveSkip(next)
}

// 0109: pipeline templates HR keeps under Hiring → Settings.
const templates = ref<{ id: string; name: string; skip_statuses: string[] }[]>([])
async function loadTemplates(): Promise<void> {
  const { data, error: err } = await supabase.from('pipeline_templates').select('id, name, skip_statuses').order('name')
  if (err) console.error('Pipeline templates load failed:', err.message)
  templates.value = data ?? []
}
function applyTemplate(id: string): void {
  const t = templates.value.find((x) => x.id === id)
  if (t) void saveSkip(t.skip_statuses)
}

async function saveSkip(next: string[]): Promise<void> {
  savingPipeline.value = true
  error.value = null
  const { error: err } = await supabase.from('jobs').update({ skip_statuses: next }).eq('id', props.jobId)
  savingPipeline.value = false
  if (err) {
    console.error('Saving the pipeline failed:', err.message)
    error.value = err.message
    return
  }
  emit('changed')
}

watch(() => props.jobId, load)
onMounted(() => {
  void load()
  void loadTemplates()
})
</script>

<template>
  <div class="board-wrap">
    <div class="card pipeline-setup">
      <div>
        <h2>Pipeline</h2>
        <p v-if="pipelineEditable">Switch off the optional stages this job does not use. It locks once the job opens.</p>
        <p v-else>Optional stages are fixed for this job.</p>
      </div>
      <div class="toggles">
        <select v-if="pipelineEditable && templates.length" id="pipeline-template" :value="''" aria-label="Pipeline template" :disabled="savingPipeline" @change="applyTemplate(($event.target as HTMLSelectElement).value)">
          <option value="">Use a template…</option>
          <option v-for="t in templates" :key="t.id" :value="t.id">{{ t.name }}</option>
        </select>
        <label v-for="c in optionalColumns" :key="c.key" class="toggle">
          <input
            :id="`pipeline-${c.key}`"
            type="checkbox"
            :checked="!skipStatuses.includes(c.optional!)"
            :disabled="!pipelineEditable || savingPipeline"
            @change="toggleOptional(c.optional!, ($event.target as HTMLInputElement).checked)"
          />
          {{ c.label }}
        </label>
      </div>
    </div>

    <p v-if="error" class="error" role="alert">{{ error }}</p>
    <div v-if="loading" class="empty">Loading the board…</div>
    <div v-else class="board" data-testid="pipeline-board">
      <section
        v-for="col in columns"
        :key="col.key"
        class="column"
        :class="{ droppable: dragging && col.target }"
        :aria-label="col.label"
        :data-testid="`board-col-${col.key}`"
        @dragover.prevent
        @drop.prevent="onDrop(col)"
      >
        <header>
          <strong>{{ col.label }}</strong>
          <span class="count">{{ arranged.columns[col.key]?.length ?? 0 }}</span>
          <small>{{ col.owner }}</small>
        </header>
        <article
          v-for="card in arranged.columns[col.key]"
          :key="card.id"
          class="board-card"
          :class="{ busy: busyId === card.id }"
          :draggable="canReview && card.in_play"
          :data-testid="`board-card-${card.id}`"
          @dragstart="dragging = card.id"
          @dragend="dragging = null"
        >
          <router-link :to="{ name: 'application', params: { applicationId: card.id } }">{{ card.candidate?.full_name ?? '—' }}</router-link>
          <small>{{ labels[card.sub_status_key ?? ''] ?? card.sub_status_key ?? '' }}</small>
          <select
            v-if="canReview && card.in_play"
            :id="`move-${card.id}`"
            class="move"
            :disabled="busyId === card.id"
            aria-label="Move to"
            @change="onMoveSelect(card, ($event.target as HTMLSelectElement).value); ($event.target as HTMLSelectElement).value = ''"
          >
            <option value="">Move to…</option>
            <option v-for="c in columns.filter((x) => dropTarget(x, card))" :key="c.key" :value="c.key">{{ c.label }}</option>
          </select>
        </article>
      </section>
    </div>
    <p v-if="!loading" class="hint">{{ arranged.closed }} closed application{{ arranged.closed === 1 ? '' : 's' }} (rejected or withdrawn) are not on the board — see Applications.</p>
  </div>
</template>

<style scoped>
.board-wrap { display: grid; gap: 12px; }
.pipeline-setup { display: flex; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.pipeline-setup p { margin: 4px 0 0; color: var(--muted); font-size: 12px; }
.toggles { display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }
.toggle { display: inline-flex; gap: 6px; align-items: center; font-size: 13px; }
.board { display: grid; grid-auto-flow: column; grid-auto-columns: minmax(180px, 1fr); gap: 10px; overflow-x: auto; padding-bottom: 6px; }
.column { background: var(--surface-2, rgba(127, 127, 127, 0.06)); border: 1px solid var(--line); border-radius: 10px; padding: 8px; display: grid; gap: 6px; align-content: start; min-height: 160px; }
.column.droppable { border-style: dashed; border-color: var(--green); }
.column header { display: grid; grid-template-columns: 1fr auto; gap: 2px 6px; }
.column header small { grid-column: 1 / -1; color: var(--muted); font-size: 11px; }
.count { font-variant-numeric: tabular-nums; color: var(--muted); }
.board-card { background: var(--surface, #fff); border: 1px solid var(--line); border-radius: 8px; padding: 8px; display: grid; gap: 4px; cursor: grab; }
.board-card.busy { opacity: 0.6; }
.board-card small { color: var(--muted); font-size: 11px; }
.move { font-size: 12px; }
.hint { margin: 0; color: var(--muted); font-size: 12px; }
.error { margin: 0; color: var(--red, #b42318); }
</style>
