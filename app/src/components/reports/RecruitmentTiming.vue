<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { shortDate } from '@/lib/leave'
import {
  activitySentence,
  averageDays,
  fillLine,
  offerRate,
  parseInsights,
  type RecruitmentInsights,
} from '@/lib/insights'

/**
 * The time side of the report (plan 067), from recruitment_insights (0086):
 * how long openings take to fill, how long each hire took, how many offers
 * were accepted, and the latest stage changes. The Zoho Recruit home's
 * Time-to-fill, Time-to-hire, Age of Job, Offer Acceptance and All
 * Activities, in the report's one company and range.
 */
const props = defineProps<{ companyId: string; from: string; to: string }>()

const data = ref<RecruitmentInsights | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)

const FILL_ROWS = 12
const showAllFill = ref(false)

const filled = computed(() => data.value?.fill.filter((f) => f.filled_on) ?? [])
const stillOpen = computed(() => data.value?.fill.filter((f) => !f.filled_on) ?? [])
const fillRows = computed(() => {
  const rows = data.value?.fill ?? []
  return showAllFill.value ? rows : rows.slice(0, FILL_ROWS)
})
const offersAnswered = computed(() => (data.value ? data.value.offers.accepted + data.value.offers.declined : 0))

const tiles = computed(() => {
  const d = data.value
  if (!d) return []
  const late = stillOpen.value.filter((f) => f.late_days > 0).length
  return [
    { key: 'fill', label: 'Avg days to fill', value: averageDays(filled.value), sub: `${filled.value.length} filled in range` },
    { key: 'open', label: 'Avg days open', value: averageDays(stillOpen.value), sub: `${stillOpen.value.length} still being hired for` },
    {
      key: 'hire',
      label: 'Avg days applied → hired',
      value: d.can_see_candidates ? averageDays(d.hires) : '—',
      sub: d.can_see_candidates ? `${d.hires.length} hired in range` : 'Needs candidates.view',
    },
    {
      key: 'offers',
      label: 'Offer acceptance',
      value: offerRate(d.offers),
      sub: `${d.offers.accepted} of ${offersAnswered.value} answered${d.offers.extended ? ` · ${d.offers.extended} still out` : ''}`,
    },
    { key: 'late', label: 'Past target start', value: String(late), sub: 'Open roles later than the request asked', warn: late > 0 },
  ]
})

function perPosition(applicants: number, headcount: number): string {
  return String(Math.round((applicants / Math.max(1, headcount)) * 10) / 10)
}

const pad = (n: number) => String(n).padStart(2, '0')

/** The day and the time both in the viewer's own zone — an event at 23:30 UTC is tomorrow in Skopje. */
function feedTime(iso: string): string {
  const d = new Date(iso)
  const localDay = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
  return `${shortDate(localDay)} · ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

let requestSeq = 0

async function load(): Promise<void> {
  const seq = ++requestSeq
  // Nothing to ask for: drop the previous company's figures, and the bump
  // above stops a request still in flight from landing.
  if (!props.companyId || !props.from || !props.to || props.to < props.from) {
    data.value = null
    loading.value = false
    return
  }
  loading.value = true
  error.value = null
  const { data: raw, error: err } = await supabase.rpc('recruitment_insights', {
    p_company_id: props.companyId,
    p_from: props.from,
    p_to: props.to,
  })
  if (seq !== requestSeq) return
  loading.value = false
  if (err) {
    data.value = null
    error.value = /jobs\.view/.test(err.message) ? 'You need jobs.view in this company to see its timings.' : 'Could not load the hiring timings.'
    console.error('Recruitment insights failed:', err.message)
    return
  }
  try {
    data.value = parseInsights(raw)
  } catch (e) {
    data.value = null
    error.value = 'The timings came back in an unexpected shape.'
    console.error('Insights parse failed:', e)
  }
}

onMounted(load)
watch(() => [props.companyId, props.from, props.to], load)
</script>

<template>
  <section class="timing" :class="{ dim: loading && data }" aria-labelledby="timing-heading" data-testid="recruitment-timing">
    <div class="section-label"><span id="timing-heading">Hiring speed</span> <small>How long openings and hires take.</small></div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else-if="loading && !data" class="card empty">Timing…</div>

    <template v-else-if="data">
      <div class="tiles">
        <div v-for="t in tiles" :key="t.key" class="card tile" :data-testid="`timing-${t.key}`">
          <span class="tile-label">{{ t.label }}</span>
          <span class="tile-value" :class="{ warn: t.warn }">{{ t.value }}</span>
          <small>{{ t.sub }}</small>
        </div>
      </div>

      <div class="two-up">
        <div class="card section">
          <div class="card-head">
            <div>
              <h2>Time to fill</h2>
              <p>Every opening still being hired for, and those filled in the range. Longest first.</p>
            </div>
          </div>
          <div v-if="!data.fill.length" class="empty">No openings to time in this range.</div>
          <div v-else class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Job</th>
                  <th>Opened</th>
                  <th>Per position</th>
                  <th>Days</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="f in fillRows" :key="f.job_id" class="fill-row" :data-testid="`fill-${f.job_id}`">
                  <td>
                    <router-link class="job-link" :to="{ name: 'job', params: { jobId: f.job_id } }">{{ f.title }}</router-link>
                    <small class="line" :class="{ warn: f.late_days > 0 }">{{ fillLine(f) }}</small>
                  </td>
                  <td>{{ f.opened_on ? shortDate(f.opened_on) : '—' }}</td>
                  <td data-col="per-position">{{ perPosition(f.applicants, f.headcount) }}</td>
                  <td data-col="days" class="days" :class="{ done: f.filled_on }">{{ f.days }}</td>
                </tr>
              </tbody>
            </table>
            <button
              v-if="data.fill.length > FILL_ROWS"
              class="more linkish"
              type="button"
              @click="showAllFill = !showAllFill"
            >{{ showAllFill ? 'Show fewer' : `Show all ${data.fill.length} openings` }}</button>
          </div>
        </div>

        <div class="card section">
          <div class="card-head">
            <div>
              <h2>Time to hire</h2>
              <p>Each hire in the range, from the day they applied.</p>
            </div>
          </div>
          <div v-if="!data.can_see_candidates" class="empty">Needs candidates.view in this company.</div>
          <div v-else-if="!data.hires.length" class="empty">No hires in this range.</div>
          <div v-else class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Candidate</th>
                  <th>Job</th>
                  <th>Hired</th>
                  <th>Days</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="h in data.hires" :key="h.application_id" class="hire-row">
                  <td>
                    <router-link class="job-link" :to="{ name: 'application', params: { applicationId: h.application_id } }">{{ h.candidate }}</router-link>
                  </td>
                  <td>{{ h.job }}</td>
                  <td>{{ shortDate(h.hired_on) }}</td>
                  <td data-col="days" class="days">{{ h.days }}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="card section">
        <div class="card-head">
          <div>
            <h2>Recent activity</h2>
            <p>Who moved which candidate, newest first — the latest 60 in the range.</p>
          </div>
        </div>
        <div v-if="!data.can_see_candidates" class="empty">Needs candidates.view in this company.</div>
        <div v-else-if="!data.activity.length" class="empty">Nobody moved a candidate in this range.</div>
        <ul v-else class="feed">
          <li v-for="(a, i) in data.activity" :key="`${a.application_id}-${a.at}-${i}`" class="feed-row">
            <time :datetime="a.at">{{ feedTime(a.at) }}</time>
            <router-link class="feed-text" :to="{ name: 'application', params: { applicationId: a.application_id } }">{{ activitySentence(a) }}</router-link>
          </li>
        </ul>
      </div>
    </template>
  </section>
</template>

<style scoped>
.timing { margin-top: 8px; }
.timing.dim { opacity: 0.6; }
.section-label { display: flex; align-items: baseline; gap: 10px; margin: 0 0 12px; font-size: 13px; font-weight: 650; letter-spacing: 0.01em; }
.section-label small { font-size: 12px; font-weight: 400; color: var(--muted); }
.tiles { display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; margin-bottom: 20px; }
@media (max-width: 960px) { .tiles { grid-template-columns: repeat(2, 1fr); } }
.tile { display: flex; flex-direction: column; gap: 6px; padding: 16px 18px; }
.tile-label { font-size: 11px; color: var(--muted); font-weight: 550; }
.tile-value { font-size: 24px; font-weight: 750; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
.tile small { font-size: 11px; color: var(--muted); }
.warn { color: var(--amber); }
.section { margin-bottom: 20px; }
.two-up { display: grid; grid-template-columns: 3fr 2fr; gap: 20px; }
@media (max-width: 960px) { .two-up { grid-template-columns: 1fr; } }
.job-link { color: inherit; text-decoration: none; font-weight: 550; }
.job-link:hover { color: var(--green); text-decoration: underline; }
.line { display: block; margin-top: 3px; font-size: 11px; color: var(--muted); }
.line.warn { color: var(--amber); }
.days { font-weight: 650; font-variant-numeric: tabular-nums; }
.days.done { color: var(--green-deep); }
.more { display: block; margin: 0; padding: 12px 24px 16px; border-top: 1px solid var(--line); width: 100%; text-align: left; font-size: 12px; }
.feed { list-style: none; margin: 0; padding: 0; }
.feed-row { display: grid; grid-template-columns: 120px 1fr; gap: 14px; align-items: baseline; padding: 11px 24px; border-top: 1px solid var(--line); }
@media (max-width: 600px) { .feed-row { grid-template-columns: 1fr; gap: 3px; } }
.feed-row time { font-size: 11px; color: var(--muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
.feed-text { font-size: 12px; color: var(--ink); text-decoration: none; }
.feed-text:hover { color: var(--green); text-decoration: underline; }
</style>
