<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import CompanyTile from '@/components/CompanyTile.vue'
import { brandOf } from '@/lib/companyForm'

/**
 * The holding list (plan 014): the parent company banner plus a card per
 * subsidiary, each linking to its tabbed company profile. Headcounts come
 * from one query over employment_periods, counted client-side per company
 * — never one query per company. Platform admins add companies from here
 * (the form is its own page); the database (RLS) is what enforces that.
 */

type CompanyRow = {
  id: string
  parent_company_id: string | null
  kind: string
  name: string
  short_code: string
  brand: unknown
  director: { full_name: string } | null
}

const COUNT_WORDS = ['No', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine']

const auth = useAuthStore()
const companies = ref<CompanyRow[]>([])
const headcounts = ref<Record<string, number>>({})
const loading = ref(true)
const error = ref<string | null>(null)

const holding = computed(() => companies.value.find((c) => c.kind === 'holding') ?? null)
const subsidiaries = computed(() => companies.value.filter((c) => c.kind === 'company'))

const headline = computed(() => {
  const n = subsidiaries.value.length
  const count = COUNT_WORDS[n] ?? String(n)
  return `${count} ${n === 1 ? 'company' : 'companies'}. One workspace.`
})

function headcountFor(companyId: string): number {
  return headcounts.value[companyId] ?? 0
}

function cardMeta(c: CompanyRow): string {
  const n = headcountFor(c.id)
  const people = `${n} ${n === 1 ? 'person' : 'people'}`
  return c.director ? `${people} · ${c.director.full_name}, Director` : people
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null

  const [companiesRes, employmentRes] = await Promise.all([
    supabase
      .from('companies')
      .select(
        `id, parent_company_id, kind, name, short_code, brand,
         director:people!companies_director_person_id_fkey(full_name)`,
      )
      .is('archived_at', null)
      .order('kind', { ascending: false })
      .order('name'),
    // Departing people (end date set, not yet former) still count as employed.
    supabase.from('employment_periods').select('company_id').neq('status', 'former'),
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
      <div>
        <div class="eyebrow">The holding</div>
        <h1>{{ headline }}</h1>
        <p class="page-sub">Select a company to review its people, access and hiring activity.</p>
      </div>
      <router-link v-if="auth.isAdmin" class="button" :to="{ name: 'company-new' }">
        Add company
      </router-link>
    </div>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else>
      <div v-if="loading" class="empty">Loading companies…</div>
      <div v-else-if="!companies.length" class="empty">No companies found.</div>
      <template v-else>
        <div v-if="holding" class="card holding-banner">
          <CompanyTile :short-code="holding.short_code" :brand="brandOf(holding)" size="small" />
          <div>
            <strong>{{ holding.name }}</strong>
            <small>Parent organization · {{ cardMeta(holding) }}</small>
          </div>
          <router-link class="button secondary small-btn holding-link" :to="{ name: 'company', params: { companyId: holding.id } }">
            Open →
          </router-link>
        </div>

        <div class="company-grid">
          <div v-for="c in subsidiaries" :key="c.id" class="card company-card">
            <CompanyTile :short-code="c.short_code" :brand="brandOf(c)" size="small" />
            <h2>{{ c.name }}</h2>
            <p v-if="brandOf(c).tagline" class="tagline">{{ brandOf(c).tagline }}</p>
            <p class="headcount">{{ cardMeta(c) }}</p>
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
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
  margin-bottom: 22px;
}
.page-head .button { text-decoration: none; }
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
.holding-link { margin-left: auto; font-size: 11px; padding: 7px 11px; text-decoration: none; }
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
.company-card .tagline { margin: 0 0 6px; font-size: 12px; color: var(--ink); opacity: 0.8; }
.company-card .headcount { margin: 0 0 16px; font-size: 11px; color: var(--muted); }
.company-card .button { text-decoration: none; margin-top: auto; }
</style>
