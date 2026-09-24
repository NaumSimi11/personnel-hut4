<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { BOARD_COLUMNS, jobBoard, type BoardColumnKey, type BoardRow } from '@/lib/hiringBoard'
import type { ApplicationLite, JobLite } from '@/lib/dashboard'
import { todayDb } from '@/lib/compensation'

/**
 * The hiring board (plan 067): the Zoho Recruit home's per-job pipeline.
 * Every live job anybody applied to, a count in each stage, and the furthest
 * stage reached drawn as an arrow — so a glance says which roles are moving
 * and which have stalled in screening. Each row opens the job's applicants.
 */
const props = defineProps<{ applications: ApplicationLite[]; jobs: JobLite[]; loading?: boolean }>()

const COLLAPSED_ROWS = 8
/** The same line Open positions draws: a quarter without filling it. */
const AGING_DAYS = 90

const company = ref('')
const expanded = ref(false)

const allRows = computed(() => jobBoard(props.applications, props.jobs, todayDb()))
const companies = computed(() => [...new Set(allRows.value.map((r) => r.company))].sort())
const rows = computed(() => allRows.value.filter((r) => !company.value || r.company === company.value))
// A reload that no longer carries the chosen company must not strand the
// filter on nothing, with the picker gone.
watch(companies, (list) => {
  if (company.value && !list.includes(company.value)) company.value = ''
})
const shown = computed(() => (expanded.value ? rows.value : rows.value.slice(0, COLLAPSED_ROWS)))

const TONES: Record<BoardColumnKey, string> = {
  new: 'blue',
  screening: 'blue',
  interview: 'amber',
  offer: 'gold',
  hired: 'green',
  closed: '',
}

function rowLabel(r: BoardRow): string {
  const parts = BOARD_COLUMNS.map((c) => `${c.label} ${r.counts[c.key]}`)
  return `${r.title}, ${r.company}, ${ageLabel(r.daysOpen)}: ${parts.join(', ')}`
}

function ageLabel(days: number | null): string {
  if (days === null) return 'not live yet'
  return days === 0 ? 'opened today' : `open ${days} day${days === 1 ? '' : 's'}`
}
</script>

<template>
  <div class="card board-card" data-testid="hiring-board">
    <div class="card-head">
      <div>
        <h2>Hiring pipeline</h2>
        <p>Every live job, where its candidates stand. The arrow is the furthest anyone has got.</p>
      </div>
      <label v-if="companies.length > 1 || company" class="company-pick">
        <span class="sr-only">Company</span>
        <select v-model="company" data-testid="hiring-board-company">
          <option value="">All companies</option>
          <option v-for="c in companies" :key="c" :value="c">{{ c }}</option>
        </select>
      </label>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <div v-else-if="!rows.length" class="empty">Nobody has applied to a live job yet.</div>
    <!-- Rows are links, each labelled with its whole line: a screen reader
         hears "Vue developer, Synami: Applied 92, Screening 11…" and can open
         it. The column header is for the eye only. -->
    <div v-else class="board">
      <div class="board-row head" aria-hidden="true">
        <span class="job-cell">Job</span>
        <span v-for="c in BOARD_COLUMNS" :key="c.key" class="stage-cell" :class="`top-${TONES[c.key] || 'grey'}`">{{ c.label }}</span>
      </div>
      <router-link
        v-for="r in shown"
        :key="r.jobId"
        class="board-row"
        :aria-label="rowLabel(r)"
        :to="{ name: 'job', params: { jobId: r.jobId }, query: { tab: 'applications' } }"
        :data-testid="`board-row-${r.jobId}`"
      >
        <span class="job-cell" aria-hidden="true">
          <b class="job-title"><span class="title-text" :title="r.title">{{ r.title }}</span> <span class="total">({{ r.total }})</span></b>
          <small>{{ r.company }} · <span :class="{ aging: (r.daysOpen ?? 0) >= AGING_DAYS }">{{ ageLabel(r.daysOpen) }}</span></small>
        </span>
        <span v-for="c in BOARD_COLUMNS" :key="c.key" class="stage-cell" aria-hidden="true">
          <span v-if="r.furthest === c.key" class="arrow" :class="TONES[c.key]">{{ r.counts[c.key] }}</span>
          <span v-else-if="r.counts[c.key]" class="count" :class="{ closed: c.key === 'closed' }">{{ r.counts[c.key] }}</span>
          <span v-else class="zero" aria-hidden="true">·</span>
        </span>
      </router-link>
    </div>
    <button
      v-if="!loading && rows.length > COLLAPSED_ROWS"
      class="more linkish"
      type="button"
      data-testid="hiring-board-more"
      @click="expanded = !expanded"
    >{{ expanded ? 'Show fewer' : `Show all ${rows.length} jobs` }}</button>
  </div>
</template>

<style scoped>
.board-card { grid-column: 1 / -1; margin: 0; }
.company-pick select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line-strong); border-radius: 8px; background: var(--surface); color: var(--ink); }
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
.board { overflow-x: auto; }
.board-row {
  display: grid;
  grid-template-columns: minmax(200px, 2.2fr) repeat(6, minmax(72px, 1fr));
  align-items: center;
  min-width: 640px;
  padding: 0 24px;
  border-top: 1px solid var(--line);
  color: var(--ink);
  text-decoration: none;
}
a.board-row:hover { background: #f7f9f5; }
a.board-row:focus-visible { outline: none; box-shadow: inset var(--ring); }
@media (max-width: 600px) {
  .board-row { grid-template-columns: minmax(150px, 2fr) repeat(6, minmax(64px, 1fr)); min-width: 560px; padding: 0 16px; }
}
.board-row.head { padding-top: 0; font-size: 11px; font-weight: 600; letter-spacing: 0.02em; color: var(--muted); text-transform: uppercase; }
.board-row.head .stage-cell { padding: 10px 4px; border-top: 3px solid transparent; }
.top-blue { border-top-color: #6f8fb8 !important; }
.top-amber { border-top-color: #d49a4a !important; }
.top-gold { border-top-color: var(--gold) !important; }
.top-green { border-top-color: var(--green-bright) !important; }
.top-grey { border-top-color: var(--line-strong) !important; }
.job-cell { display: grid; gap: 3px; min-width: 0; padding: 12px 12px 12px 0; }
.board-row.head .job-cell { padding: 10px 12px 10px 0; }
.job-title { display: flex; gap: 4px; min-width: 0; font-size: 13px; font-weight: 600; }
/* The title gives way, the count never does: "(266)" is the point of the row. */
.title-text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.job-cell .total { flex: none; font-weight: 400; color: var(--muted); }
.job-cell small { font-size: 11px; color: var(--muted); }
.aging { color: var(--amber); font-weight: 600; }
.stage-cell { display: flex; justify-content: center; padding: 0 4px; font-variant-numeric: tabular-nums; }
.count { font-size: 13px; font-weight: 600; }
.count.closed, .zero { color: var(--muted); font-weight: 400; }
.arrow {
  display: inline-grid;
  place-items: center;
  width: 100%;
  max-width: 96px;
  height: 30px;
  padding: 0 14px;
  font-size: 12px;
  font-weight: 700;
  color: #fff;
  background: #4f6f99;  /* each fill keeps white text above 4.5:1 */
  clip-path: polygon(0 0, calc(100% - 12px) 0, 100% 50%, calc(100% - 12px) 100%, 0 100%, 12px 50%);
}
.arrow.amber { background: #a0621c; }
.arrow.gold { background: #85661a; }
.arrow.green { background: var(--green-bright); }
.more { display: block; margin: 0; padding: 12px 24px 16px; border-top: 1px solid var(--line); width: 100%; text-align: left; font-size: 12px; }
</style>
