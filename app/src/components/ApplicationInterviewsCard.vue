<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import {
  INTERVIEW_KINDS,
  RECOMMENDATIONS,
  emptyScorecardForm,
  interviewInput,
  recommendationLabel,
  scorecardInput,
  type Criterion,
  type Rating,
  type ScorecardForm,
} from '@/lib/interviews'

/**
 * Interviews for one application, each with its scorecards (plan 018b).
 * Scheduling and scoring need candidates.review. Scorecards are blind: the
 * database hides colleagues' cards from a panel member until their own is
 * in — the list below simply shows what comes back, plus a note explaining
 * why it may be short.
 */

type Interview = {
  id: string
  kind: string
  scheduled_at: string
  duration_minutes: number
  location: string | null
  status: string
  panel: { person: { id: string; full_name: string } | null }[]
  scorecards: {
    id: string
    author_id: string
    ratings: Rating[]
    recommendation: string
    summary: string | null
    submitted_at: string
    author: { full_name: string } | null
  }[]
}

const props = defineProps<{
  applicationId: string
  companyId: string
  canReview: boolean
  criteria: Criterion[]
}>()

const auth = useAuthStore()
const interviews = ref<Interview[]>([])
const people = ref<{ id: string; full_name: string }[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const busy = ref(false)

const scheduling = ref(false)
const form = ref({ kind: 'technical', scheduledAt: '', durationMinutes: '60', location: '', panel: [] as string[] })

const scoringId = ref<string | null>(null)
const scorecard = ref<ScorecardForm>(emptyScorecardForm(props.criteria))
const scoreError = ref<string | null>(null)

const kindLabel = (key: string) => INTERVIEW_KINDS.find((k) => k.key === key)?.label ?? key

const upcoming = computed(() => interviews.value.filter((i) => i.status === 'scheduled'))
const past = computed(() => interviews.value.filter((i) => i.status !== 'scheduled'))

function onPanel(i: Interview): boolean {
  return i.panel.some((p) => p.person?.id === auth.personId)
}

function hasScored(i: Interview): boolean {
  return i.scorecards.some((s) => s.author_id === auth.personId)
}

/** A panel member who has not scored sees only their own (none) — say so. */
function blindNote(i: Interview): boolean {
  return onPanel(i) && !hasScored(i) && i.status !== 'cancelled'
}

function tally(i: Interview): string {
  if (!i.scorecards.length) return ''
  const counts: Record<string, number> = {}
  for (const s of i.scorecards) counts[s.recommendation] = (counts[s.recommendation] ?? 0) + 1
  return RECOMMENDATIONS.filter((r) => counts[r.key])
    .map((r) => `${counts[r.key]} ${r.label.toLowerCase()}`)
    .join(' · ')
}

function averageRating(s: Interview['scorecards'][number]): string {
  if (!s.ratings.length) return '—'
  const sum = s.ratings.reduce((acc, r) => acc + r.rating, 0)
  return (sum / s.ratings.length).toFixed(1)
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [ivRes, peopleRes] = await Promise.all([
    supabase
      .from('interviews')
      .select(
        `id, kind, scheduled_at, duration_minutes, location, status,
         panel:interview_panel(person:people!interview_panel_person_id_fkey(id, full_name)),
         scorecards(id, author_id, ratings, recommendation, summary, submitted_at,
           author:people!scorecards_author_id_fkey(full_name))`,
      )
      .eq('application_id', props.applicationId)
      .order('scheduled_at'),
    supabase.from('people').select('id, full_name').order('full_name'),
  ])
  if (ivRes.error) {
    error.value = 'Could not load interviews. Check your access and connection.'
    console.error('Interviews load failed:', ivRes.error.message)
  }
  interviews.value = (ivRes.data ?? []) as Interview[]
  people.value = peopleRes.data ?? []
  loading.value = false
}

function startScheduling(): void {
  scheduling.value = true
  error.value = null
  form.value = { kind: 'technical', scheduledAt: '', durationMinutes: '60', location: '', panel: [] }
}

async function saveInterview(): Promise<void> {
  error.value = null
  const parsed = interviewInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the interview details.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase
    .from('interviews')
    .insert({
      application_id: props.applicationId,
      company_id: props.companyId, // derived server-side; passed for the insert type
      kind: parsed.data.kind,
      scheduled_at: new Date(parsed.data.scheduledAt).toISOString(),
      duration_minutes: parsed.data.durationMinutes,
      location: parsed.data.location || null,
      created_by: auth.personId,
    })
    .select('id')
    .single()
  if (err || !data) {
    busy.value = false
    error.value = friendlyRecruitmentError(err?.message ?? 'Could not schedule the interview.')
    return
  }
  if (parsed.data.panel.length) {
    const { error: panelErr } = await supabase
      .from('interview_panel')
      .insert(parsed.data.panel.map((person_id) => ({ interview_id: data.id, person_id })))
    if (panelErr) error.value = `Interview saved, but the panel was not: ${friendlyRecruitmentError(panelErr.message)}`
  }
  busy.value = false
  scheduling.value = false
  await load()
}

async function setStatus(i: Interview, status: 'completed' | 'cancelled'): Promise<void> {
  error.value = null
  busy.value = true
  const { data, error: err } = await supabase
    .from('interviews')
    .update({ status })
    .eq('id', i.id)
    .select('id')
    .maybeSingle()
  busy.value = false
  if (err || !data) {
    error.value = friendlyRecruitmentError(err?.message ?? 'row-level security')
    return
  }
  await load()
}

function startScoring(i: Interview): void {
  scoringId.value = i.id
  scorecard.value = emptyScorecardForm(props.criteria)
  scoreError.value = null
}

function setRating(criterionId: string, rating: number): void {
  scorecard.value = {
    ...scorecard.value,
    ratings: { ...scorecard.value.ratings, [criterionId]: { ...scorecard.value.ratings[criterionId], rating } },
  }
}

function setEvidence(criterionId: string, evidence: string): void {
  scorecard.value = {
    ...scorecard.value,
    ratings: { ...scorecard.value.ratings, [criterionId]: { ...scorecard.value.ratings[criterionId], evidence } },
  }
}

async function submitScorecard(i: Interview): Promise<void> {
  scoreError.value = null
  const parsed = scorecardInput(props.criteria).safeParse(scorecard.value)
  if (!parsed.success) {
    scoreError.value = parsed.error.issues[0]?.message ?? 'Check the scorecard.'
    return
  }
  busy.value = true
  const { error: err } = await supabase.from('scorecards').insert({
    interview_id: i.id,
    application_id: props.applicationId, // derived server-side
    company_id: props.companyId, // derived server-side
    author_id: auth.personId ?? '',
    ratings: parsed.data.ratings,
    recommendation: parsed.data.recommendation,
    summary: parsed.data.summary || null,
  })
  busy.value = false
  if (err) {
    scoreError.value = /scorecards_interview_id_author_id_key/.test(err.message)
      ? 'You have already submitted a scorecard for this interview.'
      : friendlyRecruitmentError(err.message)
    return
  }
  scoringId.value = null
  await load()
}

onMounted(load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Interviews</h2>
        <p>Each interview is scored blind: colleagues' scorecards appear once yours is in.</p>
      </div>
      <button v-if="canReview && !scheduling" class="button secondary" type="button" @click="startScheduling">
        Schedule interview
      </button>
    </div>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>

    <form v-if="scheduling" class="schedule-form" @submit.prevent="saveInterview">
      <div class="grid">
        <div class="field">
          <label for="iv-kind">Kind</label>
          <select id="iv-kind" v-model="form.kind">
            <option v-for="k in INTERVIEW_KINDS" :key="k.key" :value="k.key">{{ k.label }}</option>
          </select>
        </div>
        <div class="field">
          <label for="iv-when">When</label>
          <input id="iv-when" v-model="form.scheduledAt" type="datetime-local" required />
        </div>
        <div class="field">
          <label for="iv-duration">Duration (minutes)</label>
          <input id="iv-duration" v-model="form.durationMinutes" type="number" min="15" max="480" step="15" />
        </div>
        <div class="field">
          <label for="iv-location">Location or link</label>
          <input id="iv-location" v-model="form.location" maxlength="200" placeholder="Room, address or video link" />
        </div>
      </div>
      <div class="field">
        <label for="iv-panel">Panel</label>
        <select id="iv-panel" v-model="form.panel" multiple size="4">
          <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
        </select>
        <small class="field-hint">Who is scheduled to interview. Anyone who can review candidates may still score.</small>
      </div>
      <div class="actions">
        <button class="button secondary" type="button" @click="scheduling = false">Cancel</button>
        <button class="button" type="submit" :disabled="busy">{{ busy ? 'Saving…' : 'Save interview' }}</button>
      </div>
    </form>

    <div v-if="loading" class="empty">Loading interviews…</div>
    <div v-else-if="!interviews.length && !scheduling" class="empty">No interviews scheduled yet.</div>
    <div v-else>
      <div v-for="i in [...upcoming, ...past]" :key="i.id" class="interview-card">
        <div class="interview-head">
          <div class="row-text">
            <strong>{{ kindLabel(i.kind) }} · {{ new Date(i.scheduled_at).toLocaleString() }}</strong>
            <small>
              {{ i.duration_minutes }} min
              <template v-if="i.location"> · {{ i.location }}</template>
              <template v-if="i.panel.length">
                · panel: {{ i.panel.map((p) => p.person?.full_name ?? '—').join(', ') }}
              </template>
            </small>
            <small v-if="tally(i)" class="tally">{{ tally(i) }}</small>
          </div>
          <span class="badge" :class="i.status === 'completed' ? 'green' : i.status === 'cancelled' ? '' : 'blue'">
            {{ i.status }}
          </span>
          <div v-if="canReview" class="row-actions">
            <button
              v-if="i.status === 'scheduled'"
              class="button secondary small-btn"
              type="button"
              :disabled="busy"
              @click="setStatus(i, 'completed')"
            >
              Mark completed
            </button>
            <button
              v-if="i.status === 'scheduled'"
              class="button secondary small-btn"
              type="button"
              :disabled="busy"
              @click="setStatus(i, 'cancelled')"
            >
              Cancel
            </button>
            <button
              v-if="!hasScored(i) && i.status !== 'cancelled' && scoringId !== i.id"
              class="button small-btn"
              type="button"
              @click="startScoring(i)"
            >
              Write scorecard
            </button>
          </div>
        </div>

        <p v-if="blindNote(i)" class="blind-note">
          You are on this panel: colleagues' scorecards stay hidden until you submit yours.
        </p>

        <form v-if="scoringId === i.id" class="scorecard-form" @submit.prevent="submitScorecard(i)">
          <div v-for="c in criteria" :key="c.id" class="criterion">
            <div class="criterion-head">
              <strong>{{ c.label }}</strong>
              <small v-if="c.description">{{ c.description }}</small>
            </div>
            <div class="scale" role="radiogroup" :aria-label="`Rating for ${c.label}`">
              <label v-for="n in [1, 2, 3, 4]" :key="n" class="scale-option">
                <input
                  type="radio"
                  :name="`rating-${c.id}`"
                  :value="n"
                  :checked="scorecard.ratings[c.id]?.rating === n"
                  @change="setRating(c.id, n)"
                />
                <span>{{ n }}</span>
              </label>
            </div>
            <textarea
              :id="`sc-evidence-${c.id}`"
              rows="2"
              :value="scorecard.ratings[c.id]?.evidence ?? ''"
              placeholder="Evidence — what did you see or hear?"
              @input="setEvidence(c.id, ($event.target as HTMLTextAreaElement).value)"
            ></textarea>
          </div>
          <div class="grid">
            <div class="field">
              <label for="sc-recommendation">Recommendation</label>
              <select id="sc-recommendation" v-model="scorecard.recommendation">
                <option value="">Choose…</option>
                <option v-for="r in RECOMMENDATIONS" :key="r.key" :value="r.key">{{ r.label }}</option>
              </select>
            </div>
          </div>
          <div class="field">
            <label for="sc-summary">Summary</label>
            <textarea id="sc-summary" v-model="scorecard.summary" rows="3" placeholder="Overall impression, risks, what to probe next"></textarea>
          </div>
          <p v-if="scoreError" class="error-note" role="alert">{{ scoreError }}</p>
          <div class="actions">
            <button class="button secondary" type="button" @click="scoringId = null">Cancel</button>
            <button class="button" type="submit" :disabled="busy">{{ busy ? 'Submitting…' : 'Submit scorecard' }}</button>
          </div>
        </form>

        <div v-for="s in i.scorecards" :key="s.id" class="scorecard-row">
          <div class="scorecard-head">
            <strong>{{ s.author?.full_name ?? 'A colleague' }}</strong>
            <span class="badge" :class="s.recommendation.endsWith('yes') ? 'green' : 'amber'">
              {{ recommendationLabel(s.recommendation) }}
            </span>
            <small>avg {{ averageRating(s) }} · {{ new Date(s.submitted_at).toLocaleDateString() }}</small>
          </div>
          <ul class="ratings">
            <li v-for="r in s.ratings" :key="r.criterion_id">
              <span class="rating-pill">{{ r.rating }}</span>
              <span class="rating-label">{{ r.label }}</span>
              <span v-if="r.evidence" class="rating-evidence">{{ r.evidence }}</span>
            </li>
          </ul>
          <p v-if="s.summary" class="summary">{{ s.summary }}</p>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.schedule-form { padding: 16px 24px 18px; border-top: 1px solid var(--line); background: #fafbf9; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
.field-hint { display: block; font-size: 10px; color: var(--muted); margin-top: -8px; margin-bottom: 12px; }
.field select[multiple] { height: auto; }
.actions { display: flex; gap: 9px; justify-content: flex-end; }
.interview-card { padding: 16px 24px 18px; border-top: 1px solid #edf0eb; }
.interview-head { display: flex; align-items: center; gap: 13px; flex-wrap: wrap; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.row-text .tally { color: var(--green); font-weight: 550; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.blind-note { margin: 12px 0 0; font-size: 11px; color: var(--amber); }
.scorecard-form { margin-top: 14px; padding: 16px; border: 1px solid var(--line); border-radius: 12px; background: #fafbf9; }
.criterion { display: grid; gap: 8px; margin-bottom: 16px; }
.criterion-head strong { display: block; font-size: 12px; }
.criterion-head small { display: block; font-size: 10px; color: var(--muted); margin-top: 2px; }
.scale { display: flex; gap: 8px; }
.scale-option { display: grid; place-items: center; }
.scale-option { position: relative; }
.scale-option input { position: absolute; inset: 0; width: 100%; height: 100%; margin: 0; opacity: 0; cursor: pointer; }
.scale-option span {
  display: grid;
  place-items: center;
  width: 38px;
  height: 34px;
  border: 1px solid #dce3d7;
  border-radius: 9px;
  background: #fff;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}
.scale-option input:checked + span { background: var(--green); border-color: var(--green); color: #fff; }
.scale-option input:focus-visible + span { outline: 2px solid var(--green); outline-offset: 2px; }
.criterion textarea, .scorecard-form .field textarea, .scorecard-form .field select {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 9px 11px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
.scorecard-row { margin-top: 14px; padding: 14px 16px; border: 1px solid var(--line); border-radius: 12px; }
.scorecard-head { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.scorecard-head strong { font-size: 12px; }
.scorecard-head small { font-size: 10px; color: var(--muted); }
.ratings { list-style: none; margin: 10px 0 0; padding: 0; display: grid; gap: 6px; }
.ratings li { display: flex; align-items: baseline; gap: 8px; font-size: 11px; }
.rating-pill {
  display: inline-grid;
  place-items: center;
  width: 22px;
  height: 22px;
  border-radius: 6px;
  background: var(--green-soft);
  color: var(--green);
  font-weight: 650;
  font-size: 11px;
  flex-shrink: 0;
}
.rating-label { font-weight: 550; }
.rating-evidence { color: var(--muted); }
.summary { margin: 10px 0 0; font-size: 12px; line-height: 1.6; white-space: pre-wrap; }
</style>
