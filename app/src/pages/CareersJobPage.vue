<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { z } from 'zod'
import CareersFrame, { type PublicCompany } from '@/components/CareersFrame.vue'
import { fetchCareersJob, submitApplication, type PublicBrief } from '@/lib/careersApi'

/**
 * One role's public brief and its application form (plan 019). The form
 * posts multipart to the auth service; the hidden "website" field is the
 * honeypot — real people never see or fill it.
 */

const route = useRoute()
const code = route.params.code as string
const jobId = route.params.jobId as string

const company = ref<PublicCompany | null>(null)
const job = ref<PublicBrief | null>(null)
const loading = ref(true)
const error = ref<string | null>(null)

const form = ref({ name: '', email: '', phone: '', consent: false })
const answers = ref<Record<string, string>>({})
const cv = ref<File | null>(null)
const submitting = ref(false)
const submitError = ref<string | null>(null)
const reference = ref<string | null>(null)

const CV_TYPES = ['application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document']
const CV_MAX = 10 * 1024 * 1024

const applicantInput = z.object({
  name: z.string().trim().min(2, 'Enter your full name.').max(120),
  email: z.string().trim().email('Enter a valid email address.').max(320),
  phone: z.string().trim().max(40),
  consent: z.literal(true, { errorMap: () => ({ message: 'Please confirm you are happy for us to process your application.' }) }),
})

const missingRequired = computed(() =>
  (job.value?.questions ?? []).filter((q) => q.required && !(answers.value[q.id] ?? '').trim()),
)

function setAnswer(id: string, value: string): void {
  answers.value = { ...answers.value, [id]: value }
}

function onCv(event: Event): void {
  const file = (event.target as HTMLInputElement).files?.[0] ?? null
  submitError.value = null
  if (file && !CV_TYPES.includes(file.type)) {
    submitError.value = 'Attach your CV as a PDF or Word document.'
    cv.value = null
    return
  }
  if (file && file.size > CV_MAX) {
    submitError.value = 'Your CV must be 10 MB or smaller.'
    cv.value = null
    return
  }
  cv.value = file
}

async function submit(event: Event): Promise<void> {
  submitError.value = null
  const parsed = applicantInput.safeParse(form.value)
  if (!parsed.success) {
    submitError.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  if (missingRequired.value.length) {
    submitError.value = `Please answer: ${missingRequired.value[0]?.prompt}`
    return
  }
  if (!cv.value) {
    submitError.value = 'Attach your CV as a PDF or Word document.'
    return
  }
  const data = new FormData(event.target as HTMLFormElement)
  data.set('name', parsed.data.name)
  data.set('email', parsed.data.email)
  data.set('phone', parsed.data.phone)
  data.set('consent', 'true')
  data.set(
    'answers',
    JSON.stringify(
      (job.value?.questions ?? [])
        .map((q) => ({ question_id: q.id, answer: (answers.value[q.id] ?? '').trim() }))
        .filter((a) => a.answer),
    ),
  )
  data.set('cv', cv.value, cv.value.name)
  submitting.value = true
  try {
    const result = await submitApplication(code, jobId, data)
    reference.value = result.reference
    window.scrollTo({ top: 0 })
  } catch (e) {
    submitError.value = e instanceof Error ? e.message : 'We could not send your application. Please try again.'
  } finally {
    submitting.value = false
  }
}

onMounted(async () => {
  try {
    const data = await fetchCareersJob(code, jobId)
    company.value = data.company
    job.value = data.job
    document.title = `${data.job.title} · ${data.company.name} careers`
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not load this role.'
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <CareersFrame :company="company">
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else-if="loading" class="empty">Loading…</div>

    <template v-else-if="company && job">
      <router-link class="back-link" :to="{ name: 'careers-company', params: { code: company.code.toLowerCase() } }">
        ← All roles at {{ company.name }}
      </router-link>

      <div v-if="reference" class="card thanks">
        <div class="eyebrow">Application received</div>
        <h1>Thank you — we have your application.</h1>
        <p>
          Your reference is <strong class="reference">{{ reference }}</strong>. Keep it in case you need to ask
          about your application. The {{ company.name }} team will be in touch.
        </p>
      </div>

      <template v-else>
        <div class="intro">
          <div class="eyebrow">{{ company.name }} · open role</div>
          <h1>{{ job.title }}</h1>
        </div>
        <div class="card brief">
          <p class="description">{{ job.description || 'Details to follow.' }}</p>
        </div>

        <form class="card apply" novalidate @submit.prevent="submit">
          <h2>Apply for this role</h2>
          <div class="grid">
            <div class="field">
              <label for="apply-name">Full name</label>
              <input id="apply-name" v-model="form.name" name="name" required maxlength="120" autocomplete="name" />
            </div>
            <div class="field">
              <label for="apply-email">Email</label>
              <input id="apply-email" v-model="form.email" name="email" type="email" required maxlength="320" autocomplete="email" />
            </div>
            <div class="field">
              <label for="apply-phone">Phone (optional)</label>
              <input id="apply-phone" v-model="form.phone" name="phone" type="tel" maxlength="40" autocomplete="tel" />
            </div>
          </div>

          <template v-if="job.questions.length">
            <h3>A few questions</h3>
            <div v-for="q in job.questions" :key="q.id" class="field">
              <label :for="`apply-${q.id}`">
                {{ q.prompt }}
                <span v-if="q.required" class="required">required</span>
              </label>
              <select
                v-if="q.kind === 'yes_no'"
                :id="`apply-${q.id}`"
                :value="answers[q.id] ?? ''"
                @change="setAnswer(q.id, ($event.target as HTMLSelectElement).value)"
              >
                <option value="">Choose…</option>
                <option value="yes">Yes</option>
                <option value="no">No</option>
              </select>
              <select
                v-else-if="q.kind === 'choice'"
                :id="`apply-${q.id}`"
                :value="answers[q.id] ?? ''"
                @change="setAnswer(q.id, ($event.target as HTMLSelectElement).value)"
              >
                <option value="">Choose…</option>
                <option v-for="o in q.options ?? []" :key="o" :value="o">{{ o }}</option>
              </select>
              <textarea
                v-else
                :id="`apply-${q.id}`"
                rows="3"
                maxlength="2000"
                :value="answers[q.id] ?? ''"
                @input="setAnswer(q.id, ($event.target as HTMLTextAreaElement).value)"
              ></textarea>
            </div>
          </template>

          <div class="field">
            <label for="apply-cv">Your CV</label>
            <input id="apply-cv" type="file" accept=".pdf,.doc,.docx,application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document" @change="onCv" />
            <small class="hint">PDF or Word, up to 10 MB.</small>
          </div>

          <!-- Honeypot: hidden from people, irresistible to bots. -->
          <div class="trap" aria-hidden="true">
            <label for="apply-website">Website</label>
            <input id="apply-website" name="website" type="text" tabindex="-1" autocomplete="off" />
          </div>

          <label class="consent">
            <input id="apply-consent" v-model="form.consent" type="checkbox" />
            <span>
              I'm happy for {{ company.name }} to process my application and keep it on file for this and
              similar roles.
            </span>
          </label>

          <p v-if="submitError" class="error-note" role="alert">{{ submitError }}</p>
          <div class="actions">
            <button class="button" type="submit" :disabled="submitting">
              {{ submitting ? 'Sending…' : 'Send application' }}
            </button>
          </div>
        </form>
      </template>
    </template>
  </CareersFrame>
</template>

<style scoped>
.back-link { display: inline-block; font-size: 12px; color: var(--muted); text-decoration: none; margin-bottom: 18px; }
.back-link:hover { color: var(--accent); }
.intro h1 { font-size: 26px; margin: 6px 0 16px; }
.brief { padding: 22px 24px; margin-bottom: 18px; }
.description { margin: 0; font-size: 14px; line-height: 1.75; white-space: pre-wrap; }
.apply { padding: 22px 24px 24px; }
.apply h2 { font-size: 18px; margin: 0 0 16px; }
.apply h3 { font-size: 13px; margin: 6px 0 12px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
.field textarea, .field select {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 11px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 13px;
  font-family: inherit;
  resize: vertical;
}
.field input[type='file'] { padding: 9px 10px; font-size: 12px; }
.required { font-size: 9px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin-left: 8px; }
.hint { display: block; font-size: 11px; color: var(--muted); margin-top: -8px; margin-bottom: 14px; }
.trap { position: absolute; left: -10000px; top: auto; width: 1px; height: 1px; overflow: hidden; }
.consent { display: flex; gap: 10px; align-items: flex-start; font-size: 12px; line-height: 1.6; margin: 6px 0 14px; }
.consent input { margin-top: 3px; }
.actions { display: flex; justify-content: flex-end; }
.button { background: var(--accent); border-color: var(--accent); }
.thanks { padding: 28px; }
.thanks h1 { font-size: 24px; margin: 8px 0 10px; }
.thanks p { margin: 0; font-size: 14px; line-height: 1.7; }
.reference { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: 0.06em; }
</style>
