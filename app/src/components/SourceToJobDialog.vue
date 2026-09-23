<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import CompanyFilter from '@/components/CompanyFilter.vue'
import { longDate } from '@/lib/candidatePool'
import { todayDb } from '@/lib/compensation'

/**
 * From a pool record to a job (plan 052): pick a job the viewer may recruit
 * for, name the source, and add_candidate_to_job opens the application at
 * "New". A "contact later" wait warns and asks for "Add anyway"; a "never"
 * rule refuses in the RPC's own sentence.
 *
 * Plan 060 widened what is offered. A draft job — one being written, with no
 * listing yet — is a perfectly ordinary place to park somebody, and the
 * database has always allowed it; only this dialog did not. Filled and closed
 * jobs stay out: `app.open_application` refuses them, and listing every job
 * the holding has ever closed would put a few hundred unusable rows in a
 * picker to teach one sentence. The sentence is under the heading instead.
 */

const props = defineProps<{ candidateId: string; candidateName: string; contactAgainAfter: string | null }>()
const emit = defineEmits<{ added: [applicationId: string] }>()

type JobOption = { id: string; title: string; status: string; company_id: string; company: { name: string } | null }
type SourceOption = { key: string; label: string }

/** What a candidate may be added to; `app.open_application` allows exactly these. */
const OPEN_TO_CANDIDATES = ['draft', 'ready', 'open', 'on_hold']
const DEFAULT_SOURCE = 'head_hunt'

const router = useRouter()
const auth = useAuthStore()
const dialog = ref<HTMLDialogElement | null>(null)
const jobs = ref<JobOption[]>([])
const sources = ref<SourceOption[]>([])
const companyId = ref('')
const jobId = ref('')
const sourceKey = ref(DEFAULT_SOURCE)
const loading = ref(false)
const busy = ref(false)
const error = ref<string | null>(null)

/** A wait that still holds today; the RPC judges it the same way. */
const waiting = computed(() => Boolean(props.contactAgainAfter && props.contactAgainAfter > todayDb()))

const companies = computed(() => {
  const seen = new Map<string, string>()
  jobs.value.forEach((j) => seen.set(j.company_id, j.company?.name ?? '—'))
  return [...seen].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name))
})
const groups = computed(() =>
  companies.value
    .filter((c) => !companyId.value || c.id === companyId.value)
    .map((c) => ({ ...c, jobs: jobs.value.filter((j) => j.company_id === c.id) })),
)

/** A job that is not open says so, since that is the point of offering it. */
function jobLabel(job: JobOption): string {
  return job.status === 'open' ? job.title : `${job.title} — ${job.status.replace('_', ' ')}`
}

async function open(): Promise<void> {
  error.value = null
  companyId.value = ''
  jobId.value = ''
  sourceKey.value = DEFAULT_SOURCE
  dialog.value?.showModal()
  loading.value = true
  const [jobsRes, sourcesRes] = await Promise.all([
    supabase
      .from('jobs')
      .select('id, title, status, company_id, company:companies(name)')
      .in('status', OPEN_TO_CANDIDATES)
      .order('title'),
    supabase.from('candidate_sources').select('key, label').is('archived_at', null).order('sort_order'),
  ])
  loading.value = false
  if (jobsRes.error) {
    error.value = 'Could not load the jobs. Check your access and connection.'
    console.error('Jobs load failed:', jobsRes.error.message)
    return
  }
  if (sourcesRes.error) console.error('Candidate sources load failed:', sourcesRes.error.message)
  jobs.value = ((jobsRes.data ?? []) as unknown as JobOption[]).filter((j) => auth.can(j.company_id, 'candidates.review'))
  sources.value = sourcesRes.data ?? []
}
defineExpose({ open })

function onCompany(id: string): void {
  companyId.value = id
  if (id && jobs.value.find((j) => j.id === jobId.value)?.company_id !== id) jobId.value = ''
}

async function submit(): Promise<void> {
  error.value = null
  if (!jobId.value) {
    error.value = 'Pick the job first.'
    return
  }
  busy.value = true
  const { data, error: err } = await supabase.rpc('add_candidate_to_job', {
    p_candidate_id: props.candidateId,
    p_job_id: jobId.value,
    p_source_key: sourceKey.value,
    p_override_wait: waiting.value,
  })
  busy.value = false
  if (err) {
    error.value = err.message
    return
  }
  const applicationId = (data as { application_id: string }).application_id
  dialog.value?.close()
  emit('added', applicationId)
  void router.push({ name: 'application', params: { applicationId } })
}
</script>

<template>
  <dialog ref="dialog" class="source-to-job" aria-labelledby="source-to-job-title" data-testid="source-to-job">
    <form class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">Talent pool</div>
      <h2 id="source-to-job-title">Add {{ candidateName }} to a job.</h2>
      <p class="hint">The application starts at "New". A job still in draft is fine; a filled or closed one has to be reopened first.</p>

      <p v-if="waiting && contactAgainAfter" class="wait-note" role="status">
        {{ candidateName }} asked not to be contacted before {{ longDate(contactAgainAfter) }}.
      </p>

      <div v-if="loading" class="empty">Loading jobs…</div>
      <template v-else>
        <div v-if="!jobs.length && !error" class="empty">No jobs where you may add candidates.</div>
        <template v-else>
          <div class="field">
            <CompanyFilter id="source-job-company" :model-value="companyId" :companies="companies" all-label="All companies" label="Company" @update:model-value="onCompany" />
          </div>
          <div class="field">
            <label for="source-job-select">Job</label>
            <select id="source-job-select" v-model="jobId" data-testid="source-job-select">
              <option value="">Pick a job…</option>
              <optgroup v-for="g in groups" :key="g.id" :label="g.name">
                <option v-for="j in g.jobs" :key="j.id" :value="j.id">{{ jobLabel(j) }}</option>
              </optgroup>
            </select>
          </div>
          <div class="field">
            <label for="source-job-source">Source</label>
            <select id="source-job-source" v-model="sourceKey">
              <option v-for="s in sources" :key="s.key" :value="s.key">{{ s.label }}</option>
            </select>
          </div>
        </template>
      </template>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy || loading || !jobs.length" data-testid="source-job-submit">
          {{ busy ? 'Adding…' : waiting ? 'Add anyway' : 'Add to job' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.source-to-job {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(460px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.source-to-job::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 10px; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin-bottom: 16px; }
.wait-note { margin: 0 0 14px; padding: 10px 14px; border-radius: 9px; background: #fbf1da; color: var(--amber); font-size: 12px; }
.empty { padding: 24px 0; }
.field :deep(.company-filter) { display: grid; }
.field :deep(.company-filter select) { width: 100%; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
</style>
