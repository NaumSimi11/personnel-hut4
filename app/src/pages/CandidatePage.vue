<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import CandidateFilesCard from '@/components/CandidateFilesCard.vue'
import CandidateNotesCard from '@/components/CandidateNotesCard.vue'
import ContactRuleDialog from '@/components/ContactRuleDialog.vue'
import SourceToJobDialog from '@/components/SourceToJobDialog.vue'
import { SOURCE_FALLBACK_LABEL, contactBadge, contactState, longDate } from '@/lib/candidatePool'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import { shortDate } from '@/lib/leave'
import { todayDb } from '@/lib/compensation'
import { missingRecordMessage } from '@/lib/missingRecord'

/**
 * The candidate's own record (plan 052): one person across every job —
 * where they came from, how they may be contacted, their applications in
 * the viewer's companies, the notes about the person (plan 055), the files
 * that follow them, and the details a reviewer or pool holder may correct.
 * `canEditPool` / `canEditIdentity` are hints; the policies, the field
 * guard and the RPCs decide.
 */

type Candidate = {
  id: string
  full_name: string
  email: string | null
  phone: string | null
  linkedin_url: string | null
  current_title: string | null
  current_employer: string | null
  location: string | null
  skills: string[]
  summary: string | null
  referred_by: string | null
  source_key: string
  provider: string
  provider_ref: string | null
  sourced_by: string | null
  created_at: string
  archived_at: string | null
  do_not_contact: boolean
  do_not_contact_reason: string | null
  do_not_contact_at: string | null
  contact_later: boolean
  contact_again_after: string | null
  custom: unknown
  source: { label: string } | null
  sourcer: { full_name: string } | null
  flagged_by: { full_name: string } | null
}

type ApplicationRow = {
  id: string
  company_id: string
  stage_key: string
  received_at: string
  source_key: string | null
  job: { id: string; title: string; company: { name: string } | null } | null
}

type Education = {
  institute: string | null
  degree: string | null
  major: string | null
  from: string | null
  to: string | null
  current: boolean
}

type DetailsForm = {
  fullName: string
  email: string
  phone: string
  linkedinUrl: string
  currentTitle: string
  currentEmployer: string
  location: string
  skills: string
  summary: string
  referredBy: string
  sourceKey: string
}

const ZOHO_PROVIDER = 'zoho_recruit'
const RLS_REFUSED = 'new row violates row-level security policy for table "candidates"'

const route = useRoute()
const auth = useAuthStore()
const dialogs = useDialogStore()
const candidateId = route.params.candidateId as string

const candidate = ref<Candidate | null>(null)
const applications = ref<ApplicationRow[]>([])
const sources = ref<{ key: string; label: string }[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const actionError = ref<string | null>(null)
const busy = ref(false)
const form = ref<DetailsForm>(emptyForm())
const saving = ref(false)
const saveError = ref<string | null>(null)
const saved = ref(false)
const contactDialog = ref<InstanceType<typeof ContactRuleDialog> | null>(null)
const sourceDialog = ref<InstanceType<typeof SourceToJobDialog> | null>(null)

const today = todayDb()
const canEditPool = computed(() => auth.isAdmin || auth.canAnywhere('candidates.source'))
const canEditIdentity = computed(
  () => canEditPool.value || applications.value.some((a) => auth.can(a.company_id, 'candidates.review')),
)
const sourceLabel = computed(() => candidate.value?.source?.label ?? SOURCE_FALLBACK_LABEL)
const state = computed(() => (candidate.value ? contactState(candidate.value, today) : 'ok'))
const badge = computed(() => (candidate.value ? contactBadge(candidate.value, today) : ''))
const education = computed<Education[]>(() => {
  const custom = candidate.value?.custom
  const rows = custom && typeof custom === 'object' ? (custom as { education?: unknown }).education : null
  return Array.isArray(rows) ? (rows as Education[]) : []
})
const zohoDisplayId = computed(() => {
  const custom = candidate.value?.custom
  const zoho = custom && typeof custom === 'object' ? (custom as { zoho?: { display_id?: unknown } }).zoho : null
  return typeof zoho?.display_id === 'string' ? zoho.display_id : candidate.value?.provider_ref ?? ''
})
const eyebrow = computed(() => {
  const c = candidate.value
  if (!c) return ''
  const head = canEditPool.value
    ? `Talent pool · ${sourceLabel.value} · added ${shortDate(c.created_at.slice(0, 10))} by ${c.sourcer?.full_name ?? '—'}`
    : `Candidate · ${sourceLabel.value}`
  return c.provider === ZOHO_PROVIDER ? `${head} · Imported from Zoho Recruit (${zohoDisplayId.value})` : head
})
/** Why "Add to job" is off — the sentences the RPC would answer with. */
const blockedReason = computed(() => {
  const c = candidate.value
  if (!c) return null
  if (c.archived_at) return `${c.full_name} is archived. Restore the pool record first.`
  if (c.do_not_contact) return `${c.full_name} asked not to be contacted again.`
  return null
})
const contactLine = computed(() => {
  const c = candidate.value
  if (!c) return ''
  if (state.value === 'do_not_contact') return `Asked not to be contacted: ${c.do_not_contact_reason ?? '—'}`
  if (state.value === 'wait') return c.contact_again_after ? `Contact later, after ${longDate(c.contact_again_after)}` : 'Contact later'
  return 'Can be contacted'
})

function emptyForm(): DetailsForm {
  return {
    fullName: '', email: '', phone: '', linkedinUrl: '', currentTitle: '', currentEmployer: '',
    location: '', skills: '', summary: '', referredBy: '', sourceKey: '',
  }
}

function formFrom(c: Candidate): DetailsForm {
  return {
    fullName: c.full_name,
    email: c.email ?? '',
    phone: c.phone ?? '',
    linkedinUrl: c.linkedin_url ?? '',
    currentTitle: c.current_title ?? '',
    currentEmployer: c.current_employer ?? '',
    location: c.location ?? '',
    skills: c.skills.join(', '),
    summary: c.summary ?? '',
    referredBy: c.referred_by ?? '',
    sourceKey: c.source_key,
  }
}

function skillsFrom(text: string): string[] {
  return text.split(',').map((s) => s.trim()).filter((s) => s !== '')
}

function stageBadgeClass(stage: string): string {
  if (stage === 'hired') return 'green'
  if (stage === 'offer' || stage === 'interview') return 'amber'
  if (stage === 'rejected' || stage === 'withdrawn') return ''
  return 'blue'
}

function educationLine(e: Education): string {
  const what = [e.degree, e.major].filter(Boolean).join(', ')
  const years = [e.from?.slice(0, 4), e.current ? 'now' : e.to?.slice(0, 4)].filter(Boolean).join('–')
  return [[e.institute ?? '—', what].filter(Boolean).join(' — '), years].filter(Boolean).join(' · ')
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [candidateRes, appsRes, sourcesRes] = await Promise.all([
    supabase
      .from('candidates')
      .select(
        `id, full_name, email, phone, linkedin_url, current_title, current_employer, location, skills, summary,
         referred_by, source_key, provider, provider_ref, sourced_by, created_at, archived_at,
         do_not_contact, do_not_contact_reason, do_not_contact_at, contact_later, contact_again_after, custom,
         source:candidate_sources(label),
         sourcer:people!candidates_sourced_by_fkey(full_name),
         flagged_by:people!candidates_do_not_contact_by_fkey(full_name)`,
      )
      .eq('id', candidateId)
      .maybeSingle(),
    supabase
      .from('applications')
      .select('id, company_id, stage_key, received_at, source_key, job:jobs(id, title, company:companies(name))')
      .eq('candidate_id', candidateId)
      .order('received_at', { ascending: false }),
    supabase.from('candidate_sources').select('key, label').is('archived_at', null).order('sort_order'),
  ])
  if (candidateRes.error || !candidateRes.data) {
    error.value = missingRecordMessage({
      noun: 'candidate',
      lookupFailed: Boolean(candidateRes.error),
      seesEverything: auth.isAdmin,
    })
    if (candidateRes.error) console.error('Candidate load failed:', candidateRes.error.message)
    loading.value = false
    return
  }
  if (appsRes.error) console.error('Candidate applications load failed:', appsRes.error.message)
  if (sourcesRes.error) console.error('Candidate sources load failed:', sourcesRes.error.message)
  candidate.value = candidateRes.data as unknown as Candidate
  applications.value = (appsRes.data ?? []) as unknown as ApplicationRow[]
  sources.value = sourcesRes.data ?? []
  form.value = formFrom(candidate.value)
  loading.value = false
}

function setField<K extends keyof DetailsForm>(key: K, value: DetailsForm[K]): void {
  form.value = { ...form.value, [key]: value }
  saved.value = false
}

async function saveDetails(): Promise<void> {
  if (!candidate.value) return
  saveError.value = null
  saved.value = false
  const f = form.value
  if (f.fullName.trim().length < 2) {
    saveError.value = "Enter the candidate's full name."
    return
  }
  saving.value = true
  // RLS refuses by matching zero rows, not by erroring — select the row back.
  const { data, error: err } = await supabase
    .from('candidates')
    .update({
      full_name: f.fullName.trim(),
      email: f.email.trim().toLowerCase() || null,
      phone: f.phone.trim() || null,
      linkedin_url: f.linkedinUrl.trim() || null,
      current_title: f.currentTitle.trim() || null,
      current_employer: f.currentEmployer.trim() || null,
      location: f.location.trim() || null,
      skills: skillsFrom(f.skills),
      summary: f.summary.trim() || null,
      referred_by: f.referredBy.trim() || null,
      ...(canEditPool.value && f.sourceKey ? { source_key: f.sourceKey } : {}),
    })
    .eq('id', candidate.value.id)
    .select('id')
    .maybeSingle()
  saving.value = false
  if (err || !data) {
    saveError.value = friendlyRecruitmentError(err?.message ?? RLS_REFUSED)
    return
  }
  saved.value = true
  await load()
}

async function setArchived(archived: boolean): Promise<void> {
  if (!candidate.value) return
  const c = candidate.value
  if (archived) {
    const ok = await dialogs.confirmAction({
      eyebrow: 'Talent pool',
      title: `Archive ${c.full_name}?`,
      hint: 'They leave the pool and every picker; their applications and files stay. You can restore them later.',
      confirmLabel: 'Archive',
      danger: true,
    })
    if (!ok) return
  }
  actionError.value = null
  busy.value = true
  const { data, error: err } = await supabase
    .from('candidates')
    .update({ archived_at: archived ? new Date().toISOString() : null })
    .eq('id', c.id)
    .select('id')
    .maybeSingle()
  busy.value = false
  if (err || !data) {
    actionError.value = friendlyRecruitmentError(err?.message ?? RLS_REFUSED)
    return
  }
  await load()
}

function openContactRule(): void {
  if (!candidate.value) return
  actionError.value = null
  contactDialog.value?.open(candidate.value)
}

onMounted(load)
</script>

<template>
  <div>
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-if="loading" class="empty">Loading candidate…</div>

    <template v-else-if="candidate">
      <router-link v-if="canEditPool" class="back-link" :to="{ name: 'hiring', query: { tab: 'pool' } }">← Back to the talent pool</router-link>
      <router-link v-else class="back-link" :to="{ name: 'hiring', query: { tab: 'applicants' } }">← Back to applicants</router-link>

      <div class="page-head" data-testid="candidate-page">
        <div>
          <div class="eyebrow">{{ eyebrow }}</div>
          <h1>{{ candidate.full_name }}</h1>
          <p class="meta">
            <template v-if="candidate.current_title || candidate.current_employer">
              {{ [candidate.current_title, candidate.current_employer].filter(Boolean).join(' @ ') }}
            </template>
            <template v-if="candidate.location"> · {{ candidate.location }}</template>
            <template v-if="candidate.email"> · {{ candidate.email }}</template>
            <template v-if="candidate.phone"> · {{ candidate.phone }}</template>
            <template v-if="candidate.linkedin_url"> · <a :href="candidate.linkedin_url" target="_blank" rel="noopener">LinkedIn ↗</a></template>
          </p>
          <div class="badges">
            <span v-if="badge" class="badge" :class="state === 'do_not_contact' ? 'amber' : 'blue'" data-testid="candidate-contact-badge">{{ badge }}</span>
            <span v-if="candidate.archived_at" class="badge" data-testid="candidate-archived">Archived</span>
          </div>
          <p v-if="candidate.do_not_contact" class="never-line" role="status" data-testid="candidate-never-line">
            Asked not to be contacted again — {{ candidate.do_not_contact_reason ?? '—' }}
            ({{ candidate.flagged_by?.full_name ?? '—' }}<template v-if="candidate.do_not_contact_at">, {{ shortDate(candidate.do_not_contact_at.slice(0, 10)) }}</template>)
          </p>
        </div>
        <div class="head-actions">
          <button
            class="button"
            type="button"
            :disabled="Boolean(blockedReason)"
            :title="blockedReason ?? undefined"
            data-testid="candidate-add-to-job"
            @click="sourceDialog?.open()"
          >
            Add to job
          </button>
          <button v-if="canEditPool" class="button secondary" type="button" data-testid="candidate-contact-rule" @click="openContactRule">Contact rule</button>
          <button v-if="canEditPool && !candidate.archived_at" class="button secondary" type="button" :disabled="busy" data-testid="candidate-archive" @click="setArchived(true)">Archive</button>
          <button v-else-if="canEditPool" class="button secondary" type="button" :disabled="busy" data-testid="candidate-restore" @click="setArchived(false)">Restore</button>
        </div>
      </div>
      <p v-if="actionError" class="error-note" role="alert">{{ actionError }}</p>

      <div class="layout">
        <div class="main-column">
          <div class="card" data-testid="candidate-applications">
            <div class="card-head">
              <div>
                <h2>Applications</h2>
                <p>Every job this person applied to in your companies, newest first.</p>
              </div>
            </div>
            <div v-if="!applications.length" class="empty">No applications you can see.</div>
            <div v-else>
              <div v-for="a in applications" :key="a.id" class="row" :data-testid="`candidate-application-${a.id}`">
                <div class="row-text">
                  <strong>
                    <router-link :to="{ name: 'application', params: { applicationId: a.id } }">{{ a.job?.title ?? '—' }}</router-link>
                  </strong>
                  <small>
                    {{ a.job?.company?.name ?? '—' }} · received {{ shortDate(a.received_at.slice(0, 10)) }}
                    <template v-if="a.source_key"> · via {{ sources.find((s) => s.key === a.source_key)?.label ?? a.source_key }}</template>
                  </small>
                </div>
                <span class="badge" :class="stageBadgeClass(a.stage_key)">{{ a.stage_key }}</span>
                <router-link v-if="a.job" class="button secondary small-btn" :to="{ name: 'job', params: { jobId: a.job.id }, query: { tab: 'applications' } }">Open job</router-link>
              </div>
            </div>
          </div>

          <CandidateNotesCard :candidate-id="candidate.id" :can-add="canEditPool" />

          <CandidateFilesCard :candidate-id="candidate.id" :can-edit="canEditIdentity" />

          <div class="card" data-testid="candidate-details">
            <div class="card-head">
              <div>
                <h2>Details</h2>
                <p>Who they are and what they do. Where they came from is the pool holder's to change.</p>
              </div>
            </div>
            <form class="card-body" novalidate @submit.prevent="saveDetails">
              <fieldset class="fields" :disabled="!canEditIdentity">
                <div class="field">
                  <label for="cand-name">Full name</label>
                  <input id="cand-name" :value="form.fullName" maxlength="200" @input="setField('fullName', ($event.target as HTMLInputElement).value)" />
                </div>
                <div class="grid">
                  <div class="field">
                    <label for="cand-email">Email</label>
                    <input id="cand-email" :value="form.email" type="email" maxlength="320" @input="setField('email', ($event.target as HTMLInputElement).value)" />
                  </div>
                  <div class="field">
                    <label for="cand-phone">Phone</label>
                    <input id="cand-phone" :value="form.phone" maxlength="40" @input="setField('phone', ($event.target as HTMLInputElement).value)" />
                  </div>
                </div>
                <div class="field">
                  <label for="cand-linkedin">LinkedIn URL</label>
                  <input id="cand-linkedin" :value="form.linkedinUrl" maxlength="300" @input="setField('linkedinUrl', ($event.target as HTMLInputElement).value)" />
                </div>
                <div class="grid">
                  <div class="field">
                    <label for="cand-title">Current title</label>
                    <input id="cand-title" :value="form.currentTitle" maxlength="200" @input="setField('currentTitle', ($event.target as HTMLInputElement).value)" />
                  </div>
                  <div class="field">
                    <label for="cand-employer">Current employer</label>
                    <input id="cand-employer" :value="form.currentEmployer" maxlength="200" @input="setField('currentEmployer', ($event.target as HTMLInputElement).value)" />
                  </div>
                </div>
                <div class="field">
                  <label for="cand-location">Location</label>
                  <input id="cand-location" :value="form.location" maxlength="200" @input="setField('location', ($event.target as HTMLInputElement).value)" />
                </div>
                <div class="field">
                  <label for="cand-skills">Skills (comma-separated)</label>
                  <input id="cand-skills" :value="form.skills" @input="setField('skills', ($event.target as HTMLInputElement).value)" />
                </div>
                <div class="field">
                  <label for="cand-summary">Summary</label>
                  <textarea id="cand-summary" :value="form.summary" rows="4" @input="setField('summary', ($event.target as HTMLTextAreaElement).value)"></textarea>
                </div>
                <div class="field">
                  <label for="cand-referred">Referred by</label>
                  <input id="cand-referred" :value="form.referredBy" maxlength="200" @input="setField('referredBy', ($event.target as HTMLInputElement).value)" />
                </div>
              </fieldset>
              <fieldset class="fields" :disabled="!canEditPool">
                <div class="field">
                  <label for="cand-source">Source</label>
                  <select id="cand-source" :value="form.sourceKey" @change="setField('sourceKey', ($event.target as HTMLSelectElement).value)">
                    <option v-for="s in sources" :key="s.key" :value="s.key">{{ s.label }}</option>
                    <option v-if="!sources.some((s) => s.key === form.sourceKey)" :value="form.sourceKey">{{ sourceLabel }}</option>
                  </select>
                </div>
              </fieldset>
              <p v-if="saveError" class="error-note" role="alert">{{ saveError }}</p>
              <p v-if="saved" class="success-note">Details saved.</p>
              <div v-if="canEditIdentity" class="actions">
                <button class="button" type="submit" :disabled="saving" data-testid="candidate-save">{{ saving ? 'Saving…' : 'Save details' }}</button>
              </div>
            </form>
          </div>

          <div v-if="education.length" class="card" data-testid="candidate-education">
            <div class="card-head">
              <div>
                <h2>Education</h2>
                <p>As recorded on the imported profile.</p>
              </div>
            </div>
            <ul class="education">
              <li v-for="(e, i) in education" :key="i">{{ educationLine(e) }}</li>
            </ul>
          </div>
        </div>

        <aside class="side-column">
          <div class="card" data-testid="candidate-contact">
            <div class="card-head">
              <div>
                <h2>Contact</h2>
                <p>The rule every "Add to job" checks.</p>
              </div>
            </div>
            <div class="card-body">
              <p class="contact-line" data-testid="candidate-contact-line">{{ contactLine }}</p>
              <button v-if="canEditPool" class="button secondary small-btn" type="button" @click="openContactRule">Contact rule</button>
            </div>
          </div>
        </aside>
      </div>

      <ContactRuleDialog ref="contactDialog" @saved="load" />
      <SourceToJobDialog
        ref="sourceDialog"
        :candidate-id="candidate.id"
        :candidate-name="candidate.full_name"
        :contact-again-after="candidate.contact_later ? candidate.contact_again_after : null"
      />
    </template>
  </div>
</template>

<style scoped>
.back-link { display: inline-block; font-size: 11px; color: var(--muted); text-decoration: none; margin-bottom: 14px; }
.back-link:hover { color: var(--green); text-decoration: underline; }
.page-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 22px; }
.page-head > div:first-child { min-width: 0; }
.head-actions { display: flex; gap: 9px; flex-wrap: wrap; }
.meta { margin: 4px 0 0; font-size: 11px; color: var(--muted); }
.meta a { color: var(--green); }
.badges { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 10px; }
.never-line { margin: 10px 0 0; font-size: 12px; color: var(--red); }
.layout { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 18px; align-items: start; }
@media (max-width: 960px) { .layout { grid-template-columns: 1fr; } }
.main-column, .side-column { display: flex; flex-direction: column; gap: 18px; }
.row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text strong a { color: var(--ink); text-decoration: none; }
.row-text strong a:hover { color: var(--green); text-decoration: underline; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.fields { border: 0; padding: 0; margin: 0; min-width: 0; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(210px, 100%), 1fr)); gap: 0 16px; }
.field textarea { font-family: inherit; resize: vertical; }
.success-note { margin: 10px 0 0; font-size: 12px; color: #3e744e; }
.actions { display: flex; justify-content: flex-end; margin-top: 12px; }
.education { margin: 0; padding: 14px 24px 14px 40px; font-size: 12px; display: grid; gap: 6px; }
.contact-line { margin: 0 0 12px; font-size: 13px; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
</style>
