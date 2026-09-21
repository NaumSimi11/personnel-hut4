<script setup lang="ts">
import { computed, ref } from 'vue'
import { z } from 'zod'
import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import type { CandidateMatch } from '@/lib/candidatePool'
import CandidateMatches from '@/components/CandidateMatches.vue'

/**
 * Adds a candidate by hand — to this job's pipeline (job mode, `jobId`
 * given) or to the talent pool (pool mode, plan 052). Candidates are
 * recruitment identities, separate from people (blueprint §5). Everything
 * goes through upsert_sourced_candidate, which offers a match first, never
 * merges by itself: when the database answers `matches`, the form makes way
 * for CandidateMatches and the person attaches to one record, goes back, or
 * creates a new record anyway.
 */
const props = defineProps<{ jobId?: string; companyId?: string }>()
const emit = defineEmits<{ created: [id: string] }>()

type Source = { key: string; label: string }
type UpsertResult = {
  action: 'created' | 'attached' | 'updated' | 'matches'
  id: string | null
  application_id: string | null
  matches: CandidateMatch[]
}

const DEFAULT_SOURCE = 'head_hunt'
const JOB_SOURCE = 'added_by_hand'
const EMPTY_FORM = { fullName: '', email: '', phone: '', linkedinUrl: '', currentTitle: '', sourceKey: DEFAULT_SOURCE }

const dialog = ref<HTMLDialogElement | null>(null)
const form = ref({ ...EMPTY_FORM })
const sources = ref<Source[]>([])
const matches = ref<CandidateMatch[] | null>(null)
const error = ref<string | null>(null)
const busy = ref(false)

const poolMode = computed(() => !props.jobId)

const input = z.object({
  fullName: z.string().trim().min(2, "Enter the candidate's full name.").max(200),
  email: z.union([
    z.literal(''),
    z.string().trim().toLowerCase().email('Enter a valid email or leave it empty.'),
  ]),
  phone: z.union([z.literal(''), z.string().trim().max(40, 'Keep the phone number under 40 characters.')]),
  linkedinUrl: z.union([z.literal(''), z.string().trim().max(300, 'LinkedIn URL is too long.')]),
  currentTitle: z.union([z.literal(''), z.string().trim().max(200, 'Current title is too long.')]),
  sourceKey: z.string().min(1, 'Pick a source.'),
})

function open(): void {
  error.value = null
  matches.value = null
  form.value = { ...EMPTY_FORM }
  dialog.value?.showModal()
  if (poolMode.value) void loadSources()
}
defineExpose({ open })

async function loadSources(): Promise<void> {
  const { data, error: err } = await supabase
    .from('candidate_sources')
    .select('key, label')
    .is('archived_at', null)
    .order('sort_order')
  if (err) {
    console.error('Candidate sources load failed:', err.message)
    return
  }
  sources.value = (data ?? []) as Source[]
}

function submit(): void {
  void save({})
}

function attach(id: string): void {
  void save({ attach_to: id })
}

function createNew(): void {
  void save({ ignore_matches: true })
}

function back(): void {
  matches.value = null
  error.value = null
}

async function save(choice: { attach_to?: string; ignore_matches?: boolean }): Promise<void> {
  error.value = null
  const parsed = input.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  const payload = {
    full_name: parsed.data.fullName,
    email: parsed.data.email || null,
    phone: parsed.data.phone || null,
    linkedin_url: parsed.data.linkedinUrl || null,
    current_title: parsed.data.currentTitle || null,
    source_key: poolMode.value ? parsed.data.sourceKey : JOB_SOURCE,
    job_id: props.jobId ?? null,
    ...choice,
  }
  const { data, error: rpcErr } = await supabase.rpc('upsert_sourced_candidate', {
    p_provider: 'manual',
    p_ref: null,
    p: payload as Json,
  })
  busy.value = false
  if (rpcErr) {
    error.value = friendlyRecruitmentError(rpcErr.message)
    return
  }
  const result = data as UpsertResult
  if (result.action === 'matches') {
    matches.value = result.matches
    return
  }
  if (!result.id) {
    error.value = 'Could not add the candidate.'
    return
  }
  dialog.value?.close()
  emit('created', result.id)
}
</script>

<template>
  <dialog ref="dialog" class="add-candidate" :aria-labelledby="matches ? 'candidate-matches-title' : 'add-candidate-title'">
    <div v-if="matches" class="body">
      <CandidateMatches :matches="matches" :mode="poolMode ? 'pool' : 'job'" @attach="attach" @create-new="createNew" @back="back" />
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <p v-if="busy" class="saving">Saving…</p>
    </div>
    <form v-else class="body" novalidate @submit.prevent="submit">
      <div class="eyebrow">{{ poolMode ? 'Talent pool' : 'Recruitment' }}</div>
      <h2 id="add-candidate-title">{{ poolMode ? 'Add to the talent pool.' : 'Add a candidate.' }}</h2>
      <div class="field">
        <label for="ac-name">Full name</label>
        <input id="ac-name" v-model="form.fullName" required maxlength="200" />
      </div>
      <div class="grid">
        <div class="field">
          <label for="ac-email">Email (optional)</label>
          <input id="ac-email" v-model="form.email" type="email" maxlength="320" />
        </div>
        <div class="field">
          <label for="ac-phone">Phone (optional)</label>
          <input id="ac-phone" v-model="form.phone" maxlength="40" />
        </div>
        <div class="field">
          <label for="ac-linkedin">LinkedIn profile (optional)</label>
          <input id="ac-linkedin" v-model="form.linkedinUrl" type="url" maxlength="300" placeholder="https://www.linkedin.com/in/…" />
        </div>
        <div class="field">
          <label for="ac-title">Current title (optional)</label>
          <input id="ac-title" v-model="form.currentTitle" maxlength="200" />
        </div>
        <div v-if="poolMode" class="field">
          <label for="ac-source">Source</label>
          <select id="ac-source" v-model="form.sourceKey">
            <option v-for="s in sources" :key="s.key" :value="s.key">{{ s.label }}</option>
          </select>
        </div>
      </div>
      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div class="actions">
        <button class="button secondary" type="button" @click="dialog?.close()">Cancel</button>
        <button class="button" type="submit" :disabled="busy">
          {{ busy ? 'Saving…' : poolMode ? 'Add to pool' : 'Save candidate' }}
        </button>
      </div>
    </form>
  </dialog>
</template>

<style scoped>
.add-candidate {
  border: 0;
  border-radius: 15px;
  padding: 0;
  width: min(520px, calc(100vw - 36px));
  box-shadow: 0 25px 100px #122f3038;
  color: var(--ink);
}
.add-candidate::backdrop { background: #18372d70; }
.body { padding: 26px 28px; }
h2 { font-size: 19px; margin: 10px 0 14px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(210px, 100%), 1fr)); gap: 0 16px; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 14px; }
.saving { margin: 10px 0 0; font-size: 12px; color: var(--muted); }
</style>
