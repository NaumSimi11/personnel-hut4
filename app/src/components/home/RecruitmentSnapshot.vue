<script setup lang="ts">
import { computed } from 'vue'
import {
  openPositions,
  pipelineCounts,
  recentApplicants,
  stageLabel,
  type ApplicationLite,
  type JobLite,
} from '@/lib/dashboard'
import { shortDate } from '@/lib/leave'

/**
 * The prototype's "Applicant pipeline" and "Recruitment snapshot" (plan
 * 044): bars per stage across every application the viewer may see, open
 * positions with their live applicant count, the newest applicants. Each
 * row opens the job or the candidate.
 */
const props = defineProps<{
  applications: ApplicationLite[]
  jobs: JobLite[]
  /** Candidates are behind candidates.view, the roles behind jobs.view — the page passes what the viewer holds. */
  showPipeline: boolean
  showOpenings: boolean
  loading?: boolean
}>()

const counts = computed(() => pipelineCounts(props.applications))
const max = computed(() => Math.max(1, ...counts.value.map((c) => c.count)))
const positions = computed(() => openPositions(props.jobs, props.applications))
const recent = computed(() => recentApplicants(props.applications, 5))

function barHeight(count: number): string {
  return `${Math.round((count / max.value) * 88) + 6}px`
}
function badgeClass(stage: string): string {
  if (stage === 'hired') return 'green'
  if (stage === 'rejected' || stage === 'withdrawn') return ''
  if (stage === 'offer' || stage === 'interview') return 'amber'
  return 'blue'
}
</script>

<template>
  <section class="recruitment" aria-labelledby="recruitment-heading" data-testid="recruitment-snapshot">
    <div class="section-label"><span id="recruitment-heading">Recruitment</span> <small>What the pipeline holds and who just applied.</small></div>
    <div class="grid">
      <div v-if="showPipeline" class="card pipeline-card">
        <div class="card-head">
          <div>
            <h2>Applicant pipeline</h2>
            <p>The pipeline of live roles — every application to them you may see, by stage.</p>
          </div>
          <router-link class="button secondary small-btn" :to="{ name: 'hiring', query: { tab: 'applicants' } }">All applicants</router-link>
        </div>
        <div v-if="loading" class="empty">Loading…</div>
        <div v-else class="bars" role="img" :aria-label="counts.map((c) => `${c.label} ${c.count}`).join(', ')">
          <div v-for="c in counts" :key="c.key" class="bar-col">
            <span class="bar-count">{{ c.count }}</span>
            <span class="bar" :class="c.tone" :style="{ height: barHeight(c.count) }"></span>
            <span class="bar-label">{{ c.label }}</span>
          </div>
        </div>
      </div>

      <div v-if="showOpenings" class="card">
        <div class="card-head">
          <div>
            <h2>Open positions</h2>
            <p>Live roles and how many candidates are in play.</p>
          </div>
          <router-link class="button secondary small-btn" :to="{ name: 'hiring', query: { tab: 'openings' } }">All openings</router-link>
        </div>
        <div v-if="loading" class="empty">Loading…</div>
        <div v-else-if="!positions.length" class="empty">No open positions right now.</div>
        <ul v-else class="list">
          <li v-for="p in positions" :key="p.id">
            <router-link class="row" :to="{ name: 'job', params: { jobId: p.id } }">
              <span class="row-text"><b>{{ p.title }}</b><small>{{ p.company }} · {{ p.headcount }} needed</small></span>
              <span class="row-side">{{ p.applicants }} applicant{{ p.applicants === 1 ? '' : 's' }}</span>
            </router-link>
          </li>
        </ul>
      </div>

      <div v-if="showPipeline" class="card">
        <div class="card-head">
          <div>
            <h2>Recent applicants</h2>
            <p>The five newest, wherever they applied.</p>
          </div>
        </div>
        <div v-if="loading" class="empty">Loading…</div>
        <div v-else-if="!recent.length" class="empty">No applicants yet.</div>
        <ul v-else class="list">
          <li v-for="a in recent" :key="a.id">
            <router-link class="row" :to="{ name: 'application', params: { applicationId: a.id } }">
              <span class="row-text"><b>{{ a.name }}</b><small>{{ a.position }} · {{ a.company }} · {{ shortDate(a.received_at.slice(0, 10)) }}</small></span>
              <span class="badge" :class="badgeClass(a.stage)">{{ stageLabel(a.stage) }}</span>
            </router-link>
          </li>
        </ul>
      </div>
    </div>
  </section>
</template>

<style scoped>
.recruitment { margin-bottom: 22px; }
.section-label { display: flex; align-items: baseline; gap: 10px; margin: 0 0 12px; font-size: 13px; font-weight: 650; letter-spacing: 0.01em; }
.section-label small { font-size: 12px; font-weight: 400; color: var(--muted); }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(300px, 100%), 1fr)); gap: 14px; }
@media (max-width: 700px) { .grid { grid-template-columns: 1fr; } }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.bars { display: flex; align-items: flex-end; gap: 12px; min-height: 150px; padding: 12px 24px 18px; }
.bar-col { display: flex; flex-direction: column; align-items: center; justify-content: flex-end; gap: 6px; flex: 1; min-width: 0; height: 100%; }
.bar-count { font-size: 12px; font-weight: 650; font-variant-numeric: tabular-nums; }
.bar { display: block; width: 100%; max-width: 44px; border-radius: 6px 6px 3px 3px; background: #6f8fb8; transition: height 240ms var(--ease); }
.bar.green { background: var(--green-bright); }
.bar.red { background: #c77b7b; }
/* Wraps: a nowrap label was 5px wider than its own column. */
.bar-label { font-size: 11px; color: var(--muted); text-align: center; line-height: 1.25; overflow-wrap: anywhere; }
.list { list-style: none; margin: 0; padding: 0; }
.row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 24px; border-top: 1px solid var(--line); color: var(--ink); text-decoration: none; }
.row:hover { background: #f7f9f5; }
.row-text { display: grid; gap: 2px; min-width: 0; }
.row-text b { font-size: 13px; font-weight: 600; }
.row-text small { font-size: 11px; color: var(--muted); }
.row-side { font-size: 12px; color: var(--muted); white-space: nowrap; }
@media (prefers-reduced-motion: reduce) { .bar { transition: none; } }
</style>
