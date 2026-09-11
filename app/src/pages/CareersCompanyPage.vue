<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import CareersFrame, { type PublicCompany } from '@/components/CareersFrame.vue'
import { fetchCareersCompany, type PublicJobSummary } from '@/lib/careersApi'

/** A company's open roles — the public listing (plan 019). */
const route = useRoute()
const code = route.params.code as string

const company = ref<PublicCompany | null>(null)
const jobs = ref<PublicJobSummary[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

onMounted(async () => {
  try {
    const data = await fetchCareersCompany(code)
    company.value = data.company
    jobs.value = data.jobs
    document.title = `Careers · ${data.company.name}`
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not load this page.'
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <CareersFrame :company="company">
    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else-if="loading" class="empty">Loading…</div>
    <template v-else-if="company">
      <div class="intro">
        <div class="eyebrow">Careers</div>
        <h1>Work at {{ company.name }}.</h1>
        <p v-if="company.tagline" class="tagline">{{ company.tagline }}</p>
      </div>

      <div v-if="!jobs.length" class="card empty">
        No open roles right now. Check back soon.
      </div>
      <div v-else class="jobs">
        <router-link
          v-for="job in jobs"
          :key="job.id"
          class="card job"
          :to="{ name: 'careers-job', params: { code: company.code.toLowerCase(), jobId: job.id } }"
        >
          <strong>{{ job.title }}</strong>
          <p v-if="job.summary">{{ job.summary }}</p>
          <span class="cta">View role and apply →</span>
        </router-link>
      </div>
    </template>
  </CareersFrame>
</template>

<style scoped>
.intro { margin-bottom: 24px; }
.intro h1 { font-size: 28px; margin: 6px 0 8px; }
.tagline { margin: 0; font-size: 14px; color: var(--muted); }
.jobs { display: grid; gap: 12px; }
.job { display: block; padding: 20px 22px; text-decoration: none; color: inherit; }
.job:hover { border-color: var(--accent); }
.job strong { display: block; font-size: 15px; }
.job p { margin: 6px 0 10px; font-size: 12px; color: var(--muted); line-height: 1.6; }
.cta { font-size: 12px; color: var(--accent); font-weight: 600; }
</style>
