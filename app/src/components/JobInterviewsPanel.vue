<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { INTERVIEW_KINDS, recommendationLabel } from '@/lib/interviews'
import { offerStatusLabel } from '@/lib/offers'

/**
 * The job's Interviews & Offer tab (plan 018b): every scheduled interview
 * across the job's candidates, the scorecard tally each has (subject to the
 * blind rule), and where each offer stands. Actions live on the candidate
 * page; this is the recruiter's overview.
 */

type InterviewRow = {
  id: string
  kind: string
  scheduled_at: string
  status: string
  application: { id: string; candidate: { full_name: string } | null } | null
  panel: { person: { full_name: string } | null }[]
  scorecards: { recommendation: string }[]
}

type OfferRow = {
  id: string
  status: string
  terms: { salary?: number; currency?: string; start_date?: string } | null
  application: { id: string; candidate: { full_name: string } | null } | null
}

const props = defineProps<{ jobId: string }>()

const interviews = ref<InterviewRow[]>([])
const offers = ref<OfferRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const kindLabel = (key: string) => INTERVIEW_KINDS.find((k) => k.key === key)?.label ?? key
const upcoming = computed(() => interviews.value.filter((i) => i.status === 'scheduled'))
const done = computed(() => interviews.value.filter((i) => i.status !== 'scheduled'))

function tally(i: InterviewRow): string {
  if (!i.scorecards.length) return 'no scorecards yet'
  const counts: Record<string, number> = {}
  for (const s of i.scorecards) counts[s.recommendation] = (counts[s.recommendation] ?? 0) + 1
  return Object.entries(counts)
    .map(([k, n]) => `${n} ${recommendationLabel(k).toLowerCase()}`)
    .join(' · ')
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [ivRes, offersRes] = await Promise.all([
    supabase
      .from('interviews')
      .select(
        `id, kind, scheduled_at, status,
         application:applications!inner(id, job_id, candidate:candidates(full_name)),
         panel:interview_panel(person:people!interview_panel_person_id_fkey(full_name)),
         scorecards(recommendation)`,
      )
      .eq('application.job_id', props.jobId)
      .order('scheduled_at'),
    supabase
      .from('offers')
      .select('id, status, terms, application:applications!inner(id, job_id, candidate:candidates(full_name))')
      .eq('application.job_id', props.jobId)
      .order('created_at', { ascending: false }),
  ])
  if (ivRes.error || offersRes.error) {
    error.value = 'Could not load interviews and offers. Check your access and connection.'
    console.error('Interviews tab load failed:', ivRes.error?.message ?? offersRes.error?.message)
  }
  interviews.value = (ivRes.data ?? []) as unknown as InterviewRow[]
  offers.value = (offersRes.data ?? []) as unknown as OfferRow[]
  loading.value = false
}

onMounted(load)
</script>

<template>
  <div>
    <div class="card section">
      <div class="card-head">
        <div>
          <h2>Interviews</h2>
          <p>Scheduled and past interviews across this job's candidates. Score from the candidate page.</p>
        </div>
      </div>
      <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
      <div v-if="loading" class="empty">Loading…</div>
      <div v-else-if="!interviews.length" class="empty">No interviews scheduled for this job yet.</div>
      <div v-else>
        <div v-for="i in [...upcoming, ...done]" :key="i.id" class="row">
          <div class="row-text">
            <router-link
              v-if="i.application"
              class="candidate-link"
              :to="{ name: 'application', params: { applicationId: i.application.id } }"
            >
              <strong>{{ i.application.candidate?.full_name ?? '—' }}</strong>
            </router-link>
            <small>
              {{ kindLabel(i.kind) }} · {{ new Date(i.scheduled_at).toLocaleString() }}
              <template v-if="i.panel.length"> · {{ i.panel.map((p) => p.person?.full_name ?? '—').join(', ') }}</template>
              · {{ tally(i) }}
            </small>
          </div>
          <span class="badge" :class="i.status === 'completed' ? 'green' : i.status === 'cancelled' ? '' : 'blue'">{{ i.status }}</span>
        </div>
      </div>
    </div>

    <div class="card section">
      <div class="card-head">
        <div>
          <h2>Offers</h2>
          <p>Where each offer stands. Terms and transitions live on the candidate page.</p>
        </div>
      </div>
      <div v-if="loading" class="empty">Loading…</div>
      <div v-else-if="!offers.length" class="empty">No offers drafted for this job yet.</div>
      <div v-else>
        <div v-for="o in offers" :key="o.id" class="row">
          <div class="row-text">
            <router-link
              v-if="o.application"
              class="candidate-link"
              :to="{ name: 'application', params: { applicationId: o.application.id } }"
            >
              <strong>{{ o.application.candidate?.full_name ?? '—' }}</strong>
            </router-link>
            <small v-if="o.terms">
              {{ o.terms.salary?.toLocaleString() ?? '—' }} {{ o.terms.currency ?? '' }}
              <template v-if="o.terms.start_date"> · starts {{ o.terms.start_date }}</template>
            </small>
          </div>
          <span class="badge" :class="['accepted', 'approved'].includes(o.status) ? 'green' : ['in_approval', 'extended'].includes(o.status) ? 'amber' : ''">
            {{ offerStatusLabel(o.status) }}
          </span>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.section { margin-bottom: 22px; }
.row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.candidate-link { text-decoration: none; color: inherit; }
.candidate-link:hover strong { color: var(--green); text-decoration: underline; }
</style>
