<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { z } from 'zod'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import ApplicationFilesCard from '@/components/ApplicationFilesCard.vue'
import ApplicationInterviewsCard from '@/components/ApplicationInterviewsCard.vue'
import ApplicationOfferCard from '@/components/ApplicationOfferCard.vue'
import AddEmployeeDialog from '@/components/AddEmployeeDialog.vue'
import CandidateFilesCard from '@/components/CandidateFilesCard.vue'
import ImportedHireCard, { type ZohoHire } from '@/components/ImportedHireCard.vue'
import RejectApplicationDialog from '@/components/RejectApplicationDialog.vue'
import { friendlyRecruitmentError, salvageQuestions } from '@/lib/jobWorkspace'
import { contactBadge, type ContactRule } from '@/lib/candidatePool'
import { todayDb } from '@/lib/compensation'
import { answersFromRows, mergeAnswers, type AnswerRow } from '@/lib/screeningAnswers'
import CandidateHandoffDialog, { type HandoffPayload } from '@/components/CandidateHandoffDialog.vue'
import { deliverNotifications, deliverySentence } from '@/lib/notificationsApi'
import { candidateNextStep } from '@/lib/hiringJourney'
import { criteriaFor } from '@/lib/interviews'
import type { OfferTerms } from '@/lib/offers'
import { missingRecordMessage } from '@/lib/missingRecord'
import OutreachDialog, { type OutreachApplication } from '@/components/OutreachDialog.vue'
import { SUB_STATUS_STAGES, notResponding, outreachLine, subStatusesFor, type SubStatus, type SubStatusRow } from '@/lib/outreach'

/**
 * One application, everything in one place (plan 018a): who the candidate
 * is and where they came from, their files, their answers to the job's
 * screening questions, the timeline of stage changes and notes, and the
 * decision panel — a named owner, the next action and its date, the stage
 * actions, and a reasoned rejection or withdrawal. Interviews with blind
 * scorecards and the offer state machine (plan 018b) sit in the same column.
 * Since plan 052 the candidate is a holding-wide record: their files follow
 * them to every job, the contact rule shows beside the stage, and an
 * imported hire asks HR which employee record it belongs to.
 */

type Candidate = ContactRule & {
  id: string
  full_name: string
  email: string | null
  phone: string | null
  linkedin_url: string | null
  do_not_contact_reason: string | null
  custom: unknown
}

type Application = {
  id: string
  job_id: string
  company_id: string
  stage_key: string
  sub_status_key: string | null
  updated_at: string
  owner_id: string | null
  next_action: string | null
  next_action_due: string | null
  source_channel_key: string | null
  source_key: string | null
  received_at: string
  rejected_reason: string | null
  withdrawn_reason: string | null
  screening_answers: unknown
  employment_period_id: string | null
  custom: unknown
  candidate: Candidate | null
  job: {
    id: string
    title: string
    status: string
    screening_questions: unknown
    scorecard_criteria: unknown
    company: { name: string } | null
  } | null
  owner: { full_name: string } | null
  employment_period: { person_id: string } | null
}

type EventRow = {
  id: string
  kind: string
  from_stage_key: string | null
  to_stage_key: string | null
  from_sub_status_key: string | null
  to_sub_status_key: string | null
  body: string | null
  created_at: string
  actor: { full_name: string } | null
}

const STAGE_NEXT: Record<string, { to: string; label: string }[]> = {
  new: [{ to: 'screening', label: 'Move to screening' }],
  screening: [{ to: 'interview', label: 'Move to interview' }],
  interview: [{ to: 'offer', label: 'Prepare offer' }],
}

const route = useRoute()
const auth = useAuthStore()
const applicationId = route.params.applicationId as string

const application = ref<Application | null>(null)
const onboarding = ref<{ id: string; status: string; plan_tasks: { status: string; critical: boolean }[] } | null>(null)
const onboardingError = ref(false)
const onboardingGaps = computed(() => onboarding.value?.plan_tasks.filter(t => t.critical && !['done', 'skipped'].includes(t.status)).length ?? 0)
const events = ref<EventRow[]>([])
const people = ref<{ id: string; full_name: string }[]>([])
const channelLabels = ref<Record<string, string>>({})
const sourceLabels = ref<Record<string, string>>({})
const loading = ref(true)
const error = ref<string | null>(null)

const answerRows = ref<AnswerRow[]>([])
const questionsError = ref<string | null>(null)
const handoffDialog = ref<InstanceType<typeof CandidateHandoffDialog> | null>(null)
const handoffNotice = ref('')

async function refreshQuestions(): Promise<void> {
  if (!application.value) return
  questionsError.value = null
  const { data, error: err } = await supabase.from('jobs').select('screening_questions').eq('id', application.value.job_id).maybeSingle()
  if (err || !data) { questionsError.value = 'Could not load role questions. Check your access and try again.'; return }
  const parsed = salvageQuestions(data.screening_questions)
  if (parsed.lossy) { questionsError.value = 'The saved questions could not be read. Open the role to review them.'; return }
  answerRows.value = mergeAnswers(parsed.questions, answersFromRows(answerRows.value))
}

function openHandoff(mode: 'assign' | 'start' | 'outcome'): void {
  if (!application.value) return
  handoffDialog.value?.open(mode, application.value.stage_key, {
    ownerId: application.value.owner_id ?? '',
    nextAction: application.value.next_action ?? '',
    nextActionDue: application.value.next_action_due ?? '',
  })
}

async function saveHandoff(payload: HandoffPayload): Promise<void> {
  if (!application.value) throw new Error('Reload this application before continuing.')
  const current = application.value
  const terminal = payload.stage === 'rejected'
  if (current.stage_key === 'screening' && payload.stage === 'interview') {
    const missing = answerRows.value.find(r => !r.orphaned && r.question.required && !r.answer.trim())
    if (missing) throw new Error(`Answer the required question before proceeding: ${missing.question.prompt}`)
  }
  // Answers typed on the page travel with a screening outcome; an assignment edit leaves them alone.
  const { data, error: err } = await supabase.from('applications').update({
    stage_key: payload.stage,
    owner_id: terminal ? null : payload.ownerId,
    next_action: terminal ? null : payload.nextAction,
    next_action_due: terminal ? null : payload.nextActionDue,
    ...(payload.stage !== current.stage_key || terminal ? { screening_answers: answersFromRows(answerRows.value) } : {}),
    ...(terminal ? { rejected_reason: payload.note } : {}),
  }).eq('id', current.id).eq('updated_at', current.updated_at).select('id, updated_at').maybeSingle()
  if (err) throw new Error(friendlyReview(err.message))
  if (!data) throw new Error('This candidate changed since you opened the page. Cancel, refresh the page, and review the latest assignment.')
  const { error: eventErr } = await supabase.from('application_events').insert({
    application_id: current.id, actor_id: auth.personId,
    kind: payload.stage === current.stage_key ? 'note' : 'stage_change',
    from_stage_key: current.stage_key, to_stage_key: payload.stage,
    body: payload.note || `Assigned next action: ${payload.nextAction}; due ${payload.nextActionDue}.`,
  })
  handoffNotice.value = terminal ? 'Screening outcome saved. Application closed.' : 'Assignment saved.'
  // The owner hears about it when they are newly assigned or the ask changed — not on every save.
  const ownerChanged = payload.ownerId !== (current.owner_id ?? '') || payload.nextAction !== (current.next_action ?? '') || payload.stage !== current.stage_key
  if (!terminal && ownerChanged) handoffNotice.value += ' ' + deliverySentence(await deliverNotifications())
  if (eventErr) handoffNotice.value += ' The timeline note could not be saved; the assignment and outcome were saved.'
  await load()
}
const answersSaving = ref(false)
const answersError = ref<string | null>(null)
const answersSaved = ref(false)

const decision = ref({ ownerId: '', nextAction: '', nextActionDue: '' })
const decisionSaving = ref(false)
const decisionError = ref<string | null>(null)
const decisionSaved = ref(false)

const noteBody = ref('')
const noteBusy = ref(false)
const noteError = ref<string | null>(null)

const stageBusy = ref(false)
const stageError = ref<string | null>(null)

const outreachDialog = ref<InstanceType<typeof OutreachDialog> | null>(null)
const subStatusRows = ref<SubStatusRow[]>([])

const rejectDialog = ref<InstanceType<typeof RejectApplicationDialog> | null>(null)
const confirmHireDialog = ref<InstanceType<typeof AddEmployeeDialog> | null>(null)
const offerCard = ref<InstanceType<typeof ApplicationOfferCard> | null>(null)

const guidance = computed(() => candidateNextStep(application.value?.stage_key ?? ''))
function focusSection(id: string): void {
  const section = document.getElementById(id)
  section?.scrollIntoView({ block: 'start' })
  section?.focus({ preventScroll: true })
}

const criteria = computed(() => criteriaFor(application.value?.job?.scorecard_criteria))

const canReview = computed(() =>
  application.value ? auth.can(application.value.company_id, 'candidates.review') : false,
)
const isTerminal = computed(() => ['hired', 'rejected', 'withdrawn'].includes(application.value?.stage_key ?? ''))
const nextStages = computed(() => STAGE_NEXT[application.value?.stage_key ?? ''] ?? [])

// Outreach (plan 054): the lookup labels the badge and the timeline; the
// newest event on this page judges "not responding" exactly as D3 does.
const subStatuses = computed<SubStatus[]>(() => SUB_STATUS_STAGES.flatMap((stage) => subStatusesFor(subStatusRows.value, stage)))
const subStatusLabels = computed<Record<string, string>>(() => Object.fromEntries(subStatuses.value.map((s) => [s.key, s.label])))
const subStatusLabel = computed(() => subStatusLabels.value[application.value?.sub_status_key ?? ''] ?? '')
const canLogOutreach = computed(
  () => canReview.value && (SUB_STATUS_STAGES as readonly string[]).includes(application.value?.stage_key ?? ''),
)
const notRespondingNow = computed(() => {
  const a = application.value
  if (!a) return false
  const newest = events.value.reduce<string | null>((acc, e) => (acc && acc >= e.created_at ? acc : e.created_at), null)
  return notResponding(
    { stage_key: a.stage_key, sub_status_key: a.sub_status_key, last_activity_at: newest, received_at: a.received_at, job_status: a.job?.status ?? '' },
    todayDb(),
  )
})
const outreachApplications = computed<OutreachApplication[]>(() => {
  const a = application.value
  return a ? [{ id: a.id, full_name: a.candidate?.full_name ?? '—', stage_key: a.stage_key, sub_status_key: a.sub_status_key }] : []
})

// Pool holders may open the candidate's record; everyone else stays on the application.
const canOpenCandidate = computed(() => auth.isAdmin || auth.canAnywhere('candidates.source'))
// The source (052) wins over the careers channel; a row with neither was added by hand.
const viaLabel = computed(() => {
  const a = application.value
  if (!a) return 'added by hand'
  return sourceLabels.value[a.source_key ?? ''] ?? channelLabels.value[a.source_channel_key ?? ''] ?? 'added by hand'
})
const contactRule = computed(() => (application.value?.candidate ? contactBadge(application.value.candidate, todayDb()) : ''))
// The Zoho import never creates a person: a hired application without an
// employment record asks HR to confirm the proposed one (employment.edit).
const importedHire = computed<ZohoHire | null>(() => {
  const a = application.value
  if (!a || a.stage_key !== 'hired' || a.employment_period_id) return null
  const custom = a.custom as { zoho?: ZohoHire | null } | null
  if (!custom || typeof custom !== 'object' || !custom.zoho || typeof custom.zoho !== 'object') return null
  return auth.can(a.company_id, 'employment.edit') ? custom.zoho : null
})

const decisionInput = z.object({
  ownerId: z.union([z.literal(''), z.string().uuid()]),
  nextAction: z.string().trim().max(200, 'Keep the next action under 200 characters.'),
  nextActionDue: z.union([z.literal(''), z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a valid date.')]),
})

function stageBadgeClass(stage: string): string {
  if (stage === 'hired') return 'green'
  if (stage === 'offer') return 'amber'
  if (stage === 'rejected' || stage === 'withdrawn') return ''
  return 'blue'
}

function eventText(e: EventRow): string {
  if (e.kind === 'stage_change') {
    const move = `${e.from_stage_key ?? '—'} → ${e.to_stage_key ?? '—'}`
    return e.body ? `${move} · ${e.body}` : move
  }
  if (e.kind === 'outreach') return outreachLine(e, subStatusLabels.value)
  return e.body ?? ''
}

function eventLabel(e: EventRow): string {
  if (e.kind === 'stage_change') return 'Stage'
  if (e.kind === 'interview_feedback') return 'Feedback'
  if (e.kind === 'outreach') return 'Outreach'
  return 'Note'
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [appRes, eventsRes, peopleRes, channelsRes, sourcesRes, subStatusesRes] = await Promise.all([
    supabase
      .from('applications')
      .select(
        `id, job_id, company_id, stage_key, sub_status_key, updated_at, owner_id, next_action, next_action_due, source_channel_key, source_key,
         received_at, rejected_reason, withdrawn_reason, screening_answers, employment_period_id, custom,
         candidate:candidates(id, full_name, email, phone, linkedin_url, do_not_contact, do_not_contact_reason,
           contact_later, contact_again_after, custom),
         job:jobs(id, title, status, screening_questions, scorecard_criteria, company:companies(name)),
         owner:people!applications_owner_id_fkey(full_name),
         employment_period:employment_periods!applications_employment_period_id_fkey(person_id)`,
      )
      .eq('id', applicationId)
      .maybeSingle(),
    supabase
      .from('application_events')
      .select(
        'id, kind, from_stage_key, to_stage_key, from_sub_status_key, to_sub_status_key, body, created_at, actor:people!application_events_actor_id_fkey(full_name)',
      )
      .eq('application_id', applicationId)
      .order('created_at', { ascending: false }),
    supabase.from('people').select('id, full_name').order('full_name'),
    supabase.from('channels').select('key, label'),
    supabase.from('candidate_sources').select('key, label'),
    supabase.from('application_sub_statuses').select('key, stage_key, label, sort_order, archived_at').is('archived_at', null).order('sort_order'),
  ])
  if (appRes.error || !appRes.data) {
    error.value = missingRecordMessage({
      noun: 'application',
      lookupFailed: Boolean(appRes.error),
      seesEverything: auth.isAdmin,
      plural: 'it',
    })
    console.error('Application load failed:', appRes.error?.message)
    loading.value = false
    return
  }
  application.value = appRes.data as Application
  onboarding.value = null
  onboardingError.value = false
  if (application.value.stage_key === 'hired' && application.value.employment_period_id) {
    const plan = await supabase.from('plans').select('id, status, plan_tasks(status, critical)')
      .eq('employment_period_id', application.value.employment_period_id).eq('kind', 'onboarding').maybeSingle()
    onboardingError.value = Boolean(plan.error)
    onboarding.value = plan.data
  }
  events.value = (eventsRes.data ?? []) as EventRow[]
  people.value = peopleRes.data ?? []
  channelLabels.value = Object.fromEntries((channelsRes.data ?? []).map((c) => [c.key, c.label]))
  sourceLabels.value = Object.fromEntries((sourcesRes.data ?? []).map((s) => [s.key, s.label]))
  if (subStatusesRes.error) console.error('Sub-statuses load failed:', subStatusesRes.error.message)
  subStatusRows.value = subStatusesRes.data ?? []

  const questions = salvageQuestions(application.value.job?.screening_questions).questions
  answerRows.value = mergeAnswers(questions, application.value.screening_answers)
  decision.value = {
    ownerId: application.value.owner_id ?? '',
    nextAction: application.value.next_action ?? '',
    nextActionDue: application.value.next_action_due ?? '',
  }
  loading.value = false
}

function setAnswer(index: number, answer: string): void {
  answerRows.value = answerRows.value.map((r, i) => (i === index ? { ...r, answer } : r))
  answersSaved.value = false
}

async function saveAnswers(): Promise<void> {
  if (!application.value) return
  answersError.value = null
  answersSaved.value = false
  answersSaving.value = true
  // RLS refuses by matching zero rows, not by erroring — select the row back.
  const { data, error: err } = await supabase
    .from('applications')
    .update({ screening_answers: answersFromRows(answerRows.value) })
    .eq('id', application.value.id)
    .select('id, updated_at')
    .maybeSingle()
  answersSaving.value = false
  if (err || !data) {
    answersError.value = friendlyReview(err?.message ?? 'row-level security')
    return
  }
  application.value = { ...application.value, updated_at: data.updated_at }
  answersSaved.value = true
}

async function saveDecision(): Promise<void> {
  if (!application.value) return
  decisionError.value = null
  decisionSaved.value = false
  const parsed = decisionInput.safeParse(decision.value)
  if (!parsed.success) {
    decisionError.value = parsed.error.issues[0]?.message ?? 'Check the decision fields.'
    return
  }
  decisionSaving.value = true
  const { data, error: err } = await supabase
    .from('applications')
    .update({
      owner_id: parsed.data.ownerId || null,
      next_action: parsed.data.nextAction || null,
      next_action_due: parsed.data.nextActionDue || null,
    })
    .eq('id', application.value.id)
    .select('updated_at, owner_id, next_action, next_action_due, owner:people!applications_owner_id_fkey(full_name)')
    .maybeSingle()
  decisionSaving.value = false
  if (err || !data) {
    decisionError.value = friendlyReview(err?.message ?? 'row-level security')
    return
  }
  const before = application.value
  application.value = { ...application.value, ...(data as Partial<Application>) }
  decisionSaved.value = true
  const live = !['hired', 'rejected', 'withdrawn'].includes(before.stage_key)
  const ownerChanged = data.owner_id !== before.owner_id || data.next_action !== before.next_action
  if (live && data.owner_id && ownerChanged) handoffNotice.value = 'Assignment saved. ' + deliverySentence(await deliverNotifications())
}

async function addNote(): Promise<void> {
  if (!application.value) return
  const body = noteBody.value.trim()
  if (!body) {
    noteError.value = 'Write the note first.'
    return
  }
  noteError.value = null
  noteBusy.value = true
  const { error: err } = await supabase.from('application_events').insert({
    application_id: application.value.id,
    kind: 'note',
    body,
    actor_id: auth.personId,
  })
  noteBusy.value = false
  if (err) {
    noteError.value = friendlyReview(err.message)
    return
  }
  noteBody.value = ''
  await load()
}

async function changeStage(to: string, body?: string, extra: Record<string, unknown> = {}): Promise<void> {
  if (!application.value) return
  stageError.value = null
  stageBusy.value = true
  const from = application.value.stage_key
  // Guard on the stage this screen last saw: a colleague who moved the
  // application meanwhile makes this a no-op rather than a wrong transition.
  const { data, error: err } = await supabase
    .from('applications')
    .update({ stage_key: to, ...extra })
    .eq('id', application.value.id)
    .eq('stage_key', from)
    .select('id')
    .maybeSingle()
  if (err || !data) {
    stageBusy.value = false
    stageError.value = err
      ? friendlyReview(err.message)
      : 'This application changed since you opened it — reloading.'
    if (!err) await load()
    return
  }
  // The timeline entry feeds the recruitment report (interviewed, stale), so a
  // failure here is shown rather than swallowed — the stage itself did move.
  const { error: eventErr } = await supabase.from('application_events').insert({
    application_id: application.value.id,
    kind: 'stage_change',
    from_stage_key: from,
    to_stage_key: to,
    body: body ?? null,
    actor_id: auth.personId,
  })
  if (eventErr) {
    stageError.value = `Stage moved, but the timeline entry could not be saved: ${eventErr.message}`
    console.error('Stage-change event insert failed:', eventErr.message)
  }
  stageBusy.value = false
  await load()
}

function onDecided(payload: { mode: 'reject' | 'withdraw'; reason: string }): void {
  if (payload.mode === 'reject') void changeStage('rejected', payload.reason, { rejected_reason: payload.reason })
  else void changeStage('withdrawn', payload.reason, { withdrawn_reason: payload.reason })
}

function openConfirmHire(): void {
  if (!application.value) return
  // An accepted offer carries the agreed start date into the hire.
  const accepted: OfferTerms | null = offerCard.value?.liveStatus() === 'accepted' ? offerCard.value.liveTerms() : null
  void confirmHireDialog.value?.open({
    applicationId: application.value.id,
    candidateName: application.value.candidate?.full_name ?? '',
    candidateEmail: application.value.candidate?.email ?? null,
    candidatePhone: application.value.candidate?.phone ?? null,
    jobTitle: application.value.job?.title ?? '',
    companyId: application.value.company_id,
    startDate: accepted?.start_date,
  })
}

function friendlyReview(message: string): string {
  if (/row-level security/.test(message)) return 'This action needs candidates.review in this company.'
  return friendlyRecruitmentError(message)
}

onMounted(load)
</script>

<template>
  <div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-if="loading" class="empty">Loading application…</div>

    <template v-else-if="application">
      <router-link
        class="back-link"
        :to="{ name: 'job', params: { jobId: application.job_id }, query: { tab: 'applications' } }"
      >
        ← Back to the job
      </router-link>

      <div class="page-head">
        <div>
          <div class="eyebrow">
            Candidate · {{ application.job?.title ?? '—' }} · {{ application.job?.company?.name ?? '—' }}
          </div>
          <h1>
            <router-link
              v-if="canOpenCandidate && application.candidate"
              class="candidate-link"
              data-testid="open-candidate"
              :to="{ name: 'candidate', params: { candidateId: application.candidate.id } }"
            >
              {{ application.candidate.full_name }}
            </router-link>
            <template v-else>{{ application.candidate?.full_name ?? '—' }}</template>
          </h1>
          <p class="meta">
            <template v-if="application.candidate?.email">{{ application.candidate.email }}</template>
            <template v-else>no email</template>
            <template v-if="application.candidate?.phone"> · {{ application.candidate.phone }}</template>
            · via {{ viaLabel }}
            · received {{ new Date(application.received_at).toLocaleDateString() }}
          </p>
        </div>
        <div class="head-badges">
          <span class="badge stage-badge" :class="stageBadgeClass(application.stage_key)">{{ application.stage_key }}</span>
          <span v-if="subStatusLabel" class="badge sub-badge" data-testid="sub-badge">{{ subStatusLabel }}</span>
          <span v-if="notRespondingNow" class="badge amber" data-testid="not-responding-badge">Not responding</span>
          <span
            v-if="contactRule"
            class="badge contact-badge"
            :class="contactRule === 'Do not contact' ? 'amber' : 'blue'"
            :title="contactRule === 'Do not contact' ? application.candidate?.do_not_contact_reason ?? undefined : undefined"
            data-testid="contact-badge"
          >
            {{ contactRule }}
          </span>
        </div>
      </div>

      <section class="card journey-focus" aria-label="Candidate next step">
        <div>
          <div class="eyebrow">{{ isTerminal ? 'Outcome' : 'Next action' }}</div>
          <h2>{{ !isTerminal && application.next_action ? application.next_action : guidance.title }}</h2>
          <p v-if="!isTerminal">Owner: {{ application.owner?.full_name ?? 'Not assigned' }} &middot; {{ application.next_action_due ? `Due ${application.next_action_due}` : 'No due date set' }}</p>
          <p v-if="!isTerminal && !application.owner">Assign an owner in Decision so this candidate has a clear point of contact.</p>
        </div>
        <template v-if="canReview && !isTerminal">
          <button v-if="application.stage_key === 'new'" class="button" type="button" @click="openHandoff('start')">Start screening</button>
          <button v-else-if="application.stage_key === 'screening'" class="button" type="button" @click="openHandoff('outcome')">Record screening outcome</button>
          <button v-else class="button" type="button" @click="focusSection(guidance.target)">{{ guidance.label }}</button>
          <button class="button secondary" type="button" @click="openHandoff('assign')">Edit assignment</button>
        </template>
        <button v-else class="button secondary" type="button" @click="focusSection(guidance.target)">{{ guidance.label }}</button>
      </section>

      <p v-if="handoffNotice" class="handoff-notice" role="status">{{ handoffNotice }}</p>
      <section v-if="application.stage_key === 'hired'" class="card journey-focus" aria-label="Onboarding handoff">
        <div><div class="eyebrow">Onboarding</div>
          <h2>{{ onboarding ? onboarding.status === 'completed' ? 'Onboarding completed' : `${onboardingGaps} critical preparations outstanding` : 'Check onboarding preparations' }}</h2>
          <p v-if="onboardingError">Could not load onboarding. Try reloading the page.</p>
          <p v-else-if="!onboarding">No onboarding plan is visible with your access.</p>
          <p v-else>Open the plan to review task owners, due dates, and readiness for the first day.</p>
        </div>
        <router-link v-if="onboarding" class="button" :to="{ name: 'onboarding-plan', params: { planId: onboarding.id } }">Open onboarding</router-link>
        <router-link v-if="application.employment_period?.person_id" class="button secondary" :to="{ name: 'person', params: { personId: application.employment_period.person_id } }">View employee record</router-link>
      </section>
      <ImportedHireCard
        v-if="importedHire"
        :application-id="application.id"
        :company-id="application.company_id"
        :zoho="importedHire"
        @changed="load"
      />

      <div class="layout">
        <div class="main-column">
          <section id="candidate-review" tabindex="-1" aria-label="Candidate files">
          <ApplicationFilesCard :application-id="application.id" :company-id="application.company_id" :can-review="canReview" />
          <CandidateFilesCard
            v-if="application.candidate"
            :candidate-id="application.candidate.id"
            :can-edit="canReview"
            heading="Candidate's files — shared across their applications"
          />
          </section>
          <div id="candidate-answers" class="card" tabindex="-1">
            <div class="card-head">
              <div>
                <h2>Screening answers</h2>
                <p>Questions saved on this role. Record the candidate's responses here during screening.</p>
              </div>
            </div>
            <div v-if="!application.job" class="error-note" role="alert">The linked role is not visible. Check your access to this role.</div>
            <div v-else-if="!answerRows.length" class="empty">No questions are saved on this role. Add them on the job's Description tab and save the description.</div>
            <div class="card-body question-tools"><router-link :to="{ name: 'job', params: { jobId: application.job_id }, query: { tab: 'description' } }">View role questions</router-link><button class="button secondary small-btn" type="button" @click="refreshQuestions">Refresh questions</button></div>
            <p v-if="questionsError" class="error-note" role="alert">{{ questionsError }}</p>
            <div v-if="answerRows.length" class="card-body">
              <div v-for="(row, i) in answerRows" :key="row.question.id" class="answer-row" :class="{ orphaned: row.orphaned }">
                <label :for="`answer-${row.question.id}`" class="question">
                  {{ row.question.prompt }}
                  <span v-if="row.question.required && !row.orphaned" class="required">required</span>
                </label>
                <select
                  v-if="row.question.kind === 'yes_no'"
                  :id="`answer-${row.question.id}`"
                  :value="row.answer"
                  :disabled="!canReview || row.orphaned"
                  @change="setAnswer(i, ($event.target as HTMLSelectElement).value)"
                >
                  <option value="">Not answered</option>
                  <option value="yes">Yes</option>
                  <option value="no">No</option>
                </select>
                <select
                  v-else-if="row.question.kind === 'choice'"
                  :id="`answer-${row.question.id}`"
                  :value="row.answer"
                  :disabled="!canReview || row.orphaned"
                  @change="setAnswer(i, ($event.target as HTMLSelectElement).value)"
                >
                  <option value="">Not answered</option>
                  <option v-for="o in row.question.options ?? []" :key="o" :value="o">{{ o }}</option>
                </select>
                <textarea
                  v-else
                  :id="`answer-${row.question.id}`"
                  rows="2"
                  :value="row.answer"
                  :readonly="!canReview || row.orphaned"
                  placeholder="Not answered"
                  @input="setAnswer(i, ($event.target as HTMLTextAreaElement).value)"
                ></textarea>
              </div>
              <p v-if="answersError" class="error-note" role="alert">{{ answersError }}</p>
              <p v-if="answersSaved" class="success-note">Answers saved.</p>
              <div v-if="canReview" class="actions">
                <button class="button" type="button" :disabled="answersSaving" @click="saveAnswers">
                  {{ answersSaving ? 'Saving…' : 'Save answers' }}
                </button>
              </div>
            </div>
          </div>

          <section id="candidate-interviews" tabindex="-1" aria-label="Candidate interviews">
          <ApplicationInterviewsCard
            :application-id="application.id"
            :company-id="application.company_id"
            :can-review="canReview"
            :criteria="criteria"
          />

          </section>
          <section id="candidate-offer" tabindex="-1" aria-label="Candidate offer">
          <ApplicationOfferCard
            ref="offerCard"
            :application-id="application.id"
            :company-id="application.company_id"
            :can-review="canReview"
            :stage="application.stage_key"
          />
          </section>

          <div class="card">
            <div class="card-head">
              <div>
                <h2>Timeline</h2>
                <p>Stage changes, outreach and notes, newest first.</p>
              </div>
            </div>
            <form v-if="canReview" class="note-form" @submit.prevent="addNote">
              <textarea id="note-body" v-model="noteBody" rows="2" placeholder="Add a note for the team…"></textarea>
              <div class="note-actions">
                <p v-if="noteError" class="error-note" role="alert">{{ noteError }}</p>
                <button class="button secondary small-btn" type="submit" :disabled="noteBusy">Add note</button>
              </div>
            </form>
            <div v-if="!events.length" class="empty">Nothing recorded yet.</div>
            <div v-else>
              <div v-for="e in events" :key="e.id" class="event-row">
                <span class="badge">{{ eventLabel(e) }}</span>
                <div class="row-text">
                  <strong>{{ eventText(e) }}</strong>
                  <small>{{ new Date(e.created_at).toLocaleString() }} · {{ e.actor?.full_name ?? 'system' }}</small>
                </div>
              </div>
            </div>
          </div>
        </div>

        <aside class="side-column">
          <div id="candidate-decision" class="card decision-panel" tabindex="-1">
            <div class="card-head">
              <div>
                <h2>Decision</h2>
                <p>Who acts next, on what, and by when.</p>
              </div>
            </div>
            <div class="card-body">
              <p>Use the guided actions above to assign work and record outcomes.</p>
              <details><summary>Manual assignment fields</summary>
              <div class="field">
                <label for="decision-owner">Owner</label>
                <select id="decision-owner" v-model="decision.ownerId" :disabled="!canReview">
                  <option value="">Unassigned</option>
                  <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
                </select>
              </div>
              <div class="field">
                <label for="decision-next">Next action</label>
                <input id="decision-next" v-model="decision.nextAction" maxlength="200" :readonly="!canReview" placeholder="e.g. Phone screen" />
              </div>
              <div class="field">
                <label for="decision-due">Due</label>
                <input id="decision-due" v-model="decision.nextActionDue" type="date" :readonly="!canReview" />
              </div>
              <p v-if="decisionError" class="error-note" role="alert">{{ decisionError }}</p>
              <p v-if="decisionSaved" class="success-note">Decision saved.</p>
              <div v-if="canReview" class="actions">
                <button class="button" type="button" :disabled="decisionSaving" @click="saveDecision">
                  {{ decisionSaving ? 'Saving…' : 'Save decision' }}
                </button>
              </div>

              </details>
              <template v-if="canReview">
                <h3 class="sub-heading">Stage</h3>
                <p v-if="stageError" class="error-note" role="alert">{{ stageError }}</p>
                <div class="stage-actions">
                  <router-link
                    v-if="application.stage_key === 'hired' && application.employment_period?.person_id"
                    class="button secondary small-btn"
                    :to="{ name: 'person', params: { personId: application.employment_period.person_id } }"
                  >
                    Open employee profile
                  </router-link>
                  <template v-else-if="!isTerminal">
                    <button
                      v-if="canLogOutreach"
                      class="button secondary small-btn"
                      type="button"
                      :disabled="stageBusy"
                      data-testid="log-outreach"
                      @click="outreachDialog?.open()"
                    >
                      Log outreach
                    </button>
                    <button
                      v-for="a in nextStages.filter(s => s.to === 'offer')"
                      :key="a.to"
                      class="button secondary small-btn"
                      type="button"
                      :disabled="stageBusy"
                      @click="changeStage(a.to)"
                    >
                      {{ a.label }}
                    </button>
                    <button
                      v-if="application.stage_key === 'offer'"
                      class="button small-btn"
                      type="button"
                      :disabled="stageBusy"
                      @click="openConfirmHire"
                    >
                      Confirm hire
                    </button>
                    <button
                      class="button secondary small-btn"
                      type="button"
                      :disabled="stageBusy"
                      @click="rejectDialog?.open('reject', application.candidate?.full_name ?? '')"
                    >
                      Reject
                    </button>
                    <button
                      class="button secondary small-btn"
                      type="button"
                      :disabled="stageBusy"
                      @click="rejectDialog?.open('withdraw', application.candidate?.full_name ?? '')"
                    >
                      Withdrawn
                    </button>
                  </template>
                  <p v-else-if="application.rejected_reason" class="reason">Rejected: {{ application.rejected_reason }}</p>
                  <p v-else-if="application.withdrawn_reason" class="reason">Withdrew: {{ application.withdrawn_reason }}</p>
                </div>
              </template>
            </div>
          </div>
        </aside>
      </div>
    </template>

    <CandidateHandoffDialog ref="handoffDialog" :people="people" :save="saveHandoff" />
    <RejectApplicationDialog ref="rejectDialog" @confirmed="onDecided" />
    <OutreachDialog ref="outreachDialog" :applications="outreachApplications" :sub-statuses="subStatuses" @logged="load" />
    <AddEmployeeDialog ref="confirmHireDialog" @created="load" />
  </div>
</template>

<style scoped>
.handoff-notice { padding: 12px 16px; background: #f4f6ef; border: 1px solid var(--line); border-radius: 8px; font-size: 12px; }
summary { cursor: pointer; margin-bottom: 12px; font-size: 12px; }
.journey-focus { padding: 20px 24px; margin-bottom: 20px; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.journey-focus > div { flex: 1; min-width: 220px; }
.journey-focus h2 { font-size: 16px; margin: 6px 0; }
.journey-focus p { color: var(--muted); font-size: 12px; margin: 6px 0; }
section[id], #candidate-decision { scroll-margin-top: 20px; }

.back-link {
  display: inline-block;
  font-size: 11px;
  color: var(--muted);
  text-decoration: none;
  margin-bottom: 14px;
}
.back-link:hover { color: var(--green); text-decoration: underline; }
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
  margin-bottom: 22px;
}
.meta { margin: 4px 0 0; font-size: 11px; color: var(--muted); }
.candidate-link { color: inherit; text-decoration: none; }
.candidate-link:hover { color: var(--green); text-decoration: underline; }
.head-badges { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.sub-badge { background: #f0f1ef; color: var(--muted); }
#candidate-review { display: flex; flex-direction: column; gap: 18px; }
.layout { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 18px; align-items: start; }
@media (max-width: 960px) { .layout { grid-template-columns: 1fr; } }
.main-column, .side-column { display: flex; flex-direction: column; gap: 18px; }
.question-tools { display: flex; gap: 14px; align-items: center; }
.main-column #candidate-interviews { order: v-bind("application?.stage_key === 'interview' ? -1 : 0"); }
.main-column #candidate-offer { order: v-bind("application?.stage_key === 'offer' ? -1 : 0"); }
.answer-row { display: grid; gap: 7px; margin-bottom: 16px; }
.answer-row.orphaned { opacity: 0.7; }
.question { font-size: 11px; font-weight: 550; color: #566653; display: flex; gap: 8px; align-items: center; }
.required { font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); font-weight: 500; }
.answer-row select, .answer-row textarea, .note-form textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 9px 11px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
.answer-row textarea[readonly] { background: #fafbf9; }
.success-note { margin: 10px 0 0; font-size: 12px; color: #3e744e; }
.actions { display: flex; justify-content: flex-end; margin-top: 12px; }
.note-form { padding: 14px 24px; border-bottom: 1px solid var(--line); background: #fafbf9; }
.note-actions { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-top: 8px; }
.note-actions .error-note { margin: 0; flex: 1; }
.event-row { display: flex; align-items: flex-start; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; }
.row-text { flex: 1; min-width: 0; }
.row-text strong { display: block; font-size: 12px; font-weight: 500; white-space: pre-wrap; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.sub-heading { font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); margin: 20px 0 10px; }
.stage-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.reason { margin: 0; font-size: 12px; line-height: 1.6; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
