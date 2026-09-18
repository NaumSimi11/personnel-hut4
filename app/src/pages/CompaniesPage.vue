<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import CompanyTile from '@/components/CompanyTile.vue'
import { brandOf } from '@/lib/companyForm'

/**
 * The holding list (plan 014): the parent company as a header band plus a
 * card per subsidiary — its mark and accent, where it is, who runs it and
 * who its HR contact is, how many people and open roles. Everything comes
 * from three queries counted client-side; never one query per company.
 * Platform admins add companies from here; the database (RLS) enforces it.
 */

type PersonRef = { full_name: string } | null
type CompanyRow = {
  id: string
  parent_company_id: string | null
  kind: string
  name: string
  short_code: string
  brand: unknown
  city: string | null
  country: string | null
  country_code: string | null
  director: PersonRef
  hr_contact: PersonRef
}
type Member = { company_id: string; person: { full_name: string } | null }

const COUNT_WORDS = ['No', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine']
const FACES = 4

const auth = useAuthStore()
const companies = ref<CompanyRow[]>([])
const members = ref<Record<string, string[]>>({})
const openRoles = ref<Record<string, number>>({})
const loading = ref(true)
const error = ref<string | null>(null)

const holding = computed(() => companies.value.find((c) => c.kind === 'holding') ?? null)
const subsidiaries = computed(() => companies.value.filter((c) => c.kind === 'company'))
const totalPeople = computed(() => Object.values(members.value).reduce((sum, list) => sum + list.length, 0))

const headline = computed(() => {
  const n = subsidiaries.value.length
  const count = COUNT_WORDS[n] ?? String(n)
  return `${count} ${n === 1 ? 'company' : 'companies'}. One workspace.`
})

function headcountFor(companyId: string): number {
  return members.value[companyId]?.length ?? 0
}
function peopleLabel(companyId: string): string {
  const n = headcountFor(companyId)
  return `${n} ${n === 1 ? 'person' : 'people'}`
}
function faces(companyId: string): string[] {
  return (members.value[companyId] ?? []).slice(0, FACES)
}
function initials(name: string): string {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0]?.toUpperCase() ?? '').join('')
}
function place(c: CompanyRow): string {
  return [c.city, c.country_code ?? c.country].filter(Boolean).join(', ')
}
function accentOf(c: CompanyRow): string {
  return brandOf(c).accent_color ?? '#26564a'
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null

  const [companiesRes, employmentRes, jobsRes] = await Promise.all([
    supabase
      .from('companies')
      .select(
        `id, parent_company_id, kind, name, short_code, brand, city, country, country_code,
         director:people!companies_director_person_id_fkey(full_name),
         hr_contact:people!companies_hr_contact_person_id_fkey(full_name)`,
      )
      .is('archived_at', null)
      .order('kind', { ascending: false })
      .order('name'),
    // Departing people (end date set, not yet former) still count as employed.
    supabase
      .from('employment_periods')
      .select('company_id, person:people!employment_periods_person_id_fkey(full_name)')
      .neq('status', 'former'),
    supabase.from('jobs').select('company_id').eq('status', 'open'),
  ])

  if (companiesRes.error) {
    error.value = 'Could not load companies. Check your access and connection.'
    console.error('Companies load failed:', companiesRes.error.message)
    loading.value = false
    return
  }
  companies.value = (companiesRes.data ?? []) as unknown as CompanyRow[]

  if (employmentRes.error) {
    console.error('Company headcounts load failed:', employmentRes.error.message)
    members.value = {}
  } else {
    const byCompany: Record<string, string[]> = {}
    for (const row of (employmentRes.data ?? []) as unknown as Member[]) {
      byCompany[row.company_id] = [...(byCompany[row.company_id] ?? []), row.person?.full_name ?? '—']
    }
    members.value = byCompany
  }
  if (jobsRes.error) {
    console.error('Open roles load failed:', jobsRes.error.message)
    openRoles.value = {}
  } else {
    const counts: Record<string, number> = {}
    for (const row of jobsRes.data ?? []) counts[row.company_id] = (counts[row.company_id] ?? 0) + 1
    openRoles.value = counts
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
        <div v-if="holding" class="card holding-banner" :style="{ '--accent': accentOf(holding) }">
          <CompanyTile :short-code="holding.short_code" :brand="brandOf(holding)" size="large" />
          <div class="holding-text">
            <div class="eyebrow">Parent organization</div>
            <strong>{{ holding.name }}</strong>
            <small>
              {{ peopleLabel(holding.id) }} employed here · {{ totalPeople }} across the group
              <template v-if="place(holding)"> · {{ place(holding) }}</template>
            </small>
            <div class="contacts">
              <span v-if="holding.director"><b>Director</b> {{ holding.director.full_name }}</span>
              <span v-if="holding.hr_contact"><b>HR</b> {{ holding.hr_contact.full_name }}</span>
            </div>
          </div>
          <router-link class="button holding-link" :to="{ name: 'company', params: { companyId: holding.id } }">
            Open →
          </router-link>
        </div>

        <div class="company-grid">
          <router-link
            v-for="c in subsidiaries"
            :key="c.id"
            class="card company-card"
            :style="{ '--accent': accentOf(c) }"
            :to="{ name: 'company', params: { companyId: c.id } }"
          >
            <div class="card-top">
              <CompanyTile :short-code="c.short_code" :brand="brandOf(c)" size="small" />
              <span v-if="place(c)" class="badge place">{{ place(c) }}</span>
            </div>
            <h2>{{ c.name }}</h2>
            <p v-if="brandOf(c).tagline" class="tagline">{{ brandOf(c).tagline }}</p>
            <div class="facts">
              <div class="fact">
                <b>{{ headcountFor(c.id) }}</b>
                <span>{{ headcountFor(c.id) === 1 ? 'person' : 'people' }}</span>
              </div>
              <div class="fact">
                <b>{{ openRoles[c.id] ?? 0 }}</b>
                <span>open {{ (openRoles[c.id] ?? 0) === 1 ? 'role' : 'roles' }}</span>
              </div>
              <div class="faces" aria-hidden="true">
                <span v-for="name in faces(c.id)" :key="name" class="avatar" :title="name">{{ initials(name) }}</span>
                <span v-if="headcountFor(c.id) > FACES" class="avatar more">+{{ headcountFor(c.id) - FACES }}</span>
              </div>
            </div>
            <div class="contacts">
              <span v-if="c.director"><b>Director</b> {{ c.director.full_name }}</span>
              <span v-if="c.hr_contact"><b>HR</b> {{ c.hr_contact.full_name }}</span>
              <span v-if="!c.director && !c.hr_contact" class="muted">No director or HR contact set</span>
            </div>
            <span class="open">Open company profile →</span>
          </router-link>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.page-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 22px; }
.page-head .button { text-decoration: none; }
.page-sub { margin: 0; font-size: 13px; color: var(--muted); }

.holding-banner {
  display: flex;
  align-items: center;
  gap: 22px;
  padding: 26px 28px;
  margin-bottom: 18px;
  background:
    radial-gradient(600px 200px at 100% 0%, color-mix(in srgb, var(--accent) 12%, transparent), transparent 70%),
    linear-gradient(135deg, #fff, #f7faf6);
  border-top: 3px solid var(--accent);
}
.holding-text { flex: 1; min-width: 200px; }
.holding-banner strong { display: block; font-size: 22px; font-weight: 700; letter-spacing: -0.02em; margin-top: 4px; }
.holding-banner small { display: block; font-size: 12px; color: var(--muted); margin-top: 4px; }
.holding-link { text-decoration: none; }

.company-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(320px, 100%), 1fr)); gap: 18px; }
.company-card {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 22px 22px 18px;
  text-decoration: none;
  color: var(--ink);
  border-top: 3px solid var(--accent);
  transition: transform 0.2s var(--ease), box-shadow 0.2s var(--ease), border-color 0.2s var(--ease);
}
.company-card:hover { transform: translateY(-2px); box-shadow: 0 1px 2px rgba(22, 36, 31, 0.05), 0 22px 40px -22px rgba(22, 36, 31, 0.45); }
.company-card:hover .open { color: var(--green-bright); }
.card-top { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.company-card h2 { margin: 6px 0 0; font-size: 20px; letter-spacing: -0.02em; }
.company-card .tagline { margin: 0; font-size: 12px; color: var(--muted); }
.badge.place { background: #eef2ec; color: var(--green-deep); }
.badge.place::before { display: none; }
.facts { display: flex; align-items: center; gap: 22px; margin-top: 6px; }
.fact b { display: block; font-size: 22px; font-weight: 700; letter-spacing: -0.03em; line-height: 1.1; }
.fact span { font-size: 11px; color: var(--muted); }
.faces { display: flex; margin-left: auto; }
.faces .avatar { width: 30px; height: 30px; font-size: 10px; margin-left: -8px; border: 2px solid #fff; box-shadow: none; }
.faces .avatar:first-child { margin-left: 0; }
.faces .avatar.more { background: #eceeea; color: var(--muted); font-weight: 600; }
.contacts { display: flex; gap: 14px; flex-wrap: wrap; font-size: 12px; color: var(--ink); padding-top: 10px; border-top: 1px solid var(--line); margin-top: 4px; }
.contacts b { font-weight: 650; color: var(--muted); font-size: 10px; text-transform: uppercase; letter-spacing: 0.08em; margin-right: 4px; }
.contacts .muted { color: var(--muted); }
.holding-banner .contacts { border-top: 0; padding-top: 6px; margin-top: 2px; }
.open { font-size: 12px; font-weight: 600; color: var(--green); margin-top: auto; transition: color 0.18s var(--ease); }
</style>
