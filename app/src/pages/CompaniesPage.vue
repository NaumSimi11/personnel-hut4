<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'

/**
 * The holding list (plan 014): the parent company banner plus a card per
 * subsidiary, each linking to its tabbed company profile. Headcounts come
 * from one query over employment_periods, counted client-side per company
 * — never one query per company.
 */

type CompanyRow = {
  id: string
  parent_company_id: string | null
  kind: string
  name: string
  short_code: string
}

const companies = ref<CompanyRow[]>([])
const headcounts = ref<Record<string, number>>({})
const loading = ref(true)
const error = ref<string | null>(null)

const holding = computed(() => companies.value.find((c) => c.kind === 'holding') ?? null)
const subsidiaries = computed(() => companies.value.filter((c) => c.kind === 'company'))

function headcountFor(companyId: string): number {
  return headcounts.value[companyId] ?? 0
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null

  const [companiesRes, employmentRes] = await Promise.all([
    supabase
      .from('companies')
      .select('id, parent_company_id, kind, name, short_code')
      .is('archived_at', null)
      .order('kind', { ascending: false })
      .order('name'),
    supabase.from('employment_periods').select('company_id').is('end_date', null),
  ])

  if (companiesRes.error) {
    error.value = 'Could not load companies. Check your access and connection.'
    console.error('Companies load failed:', companiesRes.error.message)
    loading.value = false
    return
  }
  companies.value = (companiesRes.data ?? []) as CompanyRow[]

  if (employmentRes.error) {
    console.error('Company headcounts load failed:', employmentRes.error.message)
    headcounts.value = {}
  } else {
    const counts: Record<string, number> = {}
    for (const row of employmentRes.data ?? []) {
      counts[row.company_id] = (counts[row.company_id] ?? 0) + 1
    }
    headcounts.value = counts
  }

  loading.value = false
}

onMounted(load)
</script>

<template>
  <div>
    <div class="page-head">
      <div class="eyebrow">The holding</div>
      <h1>Four companies. One workspace.</h1>
      <p class="page-sub">Select a company to review its people, access and hiring activity.</p>
    </div>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else>
      <div v-if="loading" class="empty">Loading companies…</div>
      <div v-else-if="!companies.length" class="empty">No companies found.</div>
      <template v-else>
        <div v-if="holding" class="card holding-banner">
          <span class="short-tile" aria-hidden="true">{{ holding.short_code }}</span>
          <div>
            <strong>{{ holding.name }}</strong>
            <small>Parent organization</small>
          </div>
        </div>

        <div class="company-grid">
          <div v-for="c in subsidiaries" :key="c.id" class="card company-card">
            <span class="short-tile" aria-hidden="true">{{ c.short_code }}</span>
            <h2>{{ c.name }}</h2>
            <p class="headcount">
              {{ headcountFor(c.id) }} {{ headcountFor(c.id) === 1 ? 'person' : 'people' }}
            </p>
            <router-link
              class="button secondary"
              :to="{ name: 'company', params: { companyId: c.id } }"
            >
              Open company profile →
            </router-link>
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.page-head { margin-bottom: 22px; }
.page-sub { margin: 0; font-size: 12px; color: var(--muted); }
.holding-banner {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 20px 24px;
  margin-bottom: 18px;
}
.holding-banner strong { display: block; font-size: 14px; font-weight: 650; }
.holding-banner small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.short-tile {
  display: grid;
  place-items: center;
  width: 42px;
  height: 42px;
  background: var(--green-soft);
  color: var(--green);
  border-radius: 11px;
  font-size: 15px;
  font-weight: 650;
  flex-shrink: 0;
}
.company-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 16px;
}
@media (max-width: 720px) {
  .company-grid { grid-template-columns: 1fr; }
}
.company-card { padding: 22px; display: flex; flex-direction: column; align-items: flex-start; }
.company-card h2 { margin: 14px 0 4px; }
.company-card .headcount { margin: 0 0 16px; font-size: 11px; color: var(--muted); }
.company-card .button { text-decoration: none; }
</style>
