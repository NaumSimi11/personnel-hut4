<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { handoverStatusLine, type Handover } from '@/lib/equipment'
import CompanyFilter from '@/components/CompanyFilter.vue'

/**
 * Everything that has changed hands.
 *
 * The asset page answers "what happened to this one" and a person's page
 * answers "what does this one person hold". Neither answers "what moved this
 * month", which is the question anybody doing a попис, chasing paperwork or
 * checking a leaver actually asks. It was answerable only by opening assets one
 * at a time.
 *
 * Read-only on purpose. Acting on a handover belongs where the two people
 * involved already see it — the asset and their own page — and a list that also
 * signs things invites signing without looking at what you are signing.
 */
type Row = Handover & {
  created_at: string
  company_id: string
  asset: { id: string; asset_tag: string; model: string | null } | null
  counterparty: { full_name: string } | null
  starter: { full_name: string } | null
  from_person: { full_name: string } | null
  to_person: { full_name: string } | null
  document: { version: number; archived_at: string | null } | null
}

const auth = useAuthStore()
const rows = ref<Row[]>([])
const companies = ref<{ id: string; name: string }[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const company = ref('')
const state = ref<'open' | 'all' | 'unsigned'>('open')

const shown = computed(() => {
  const byCompany = company.value === '' ? rows.value : rows.value.filter((r) => r.company_id === company.value)
  switch (state.value) {
    case 'open':
      return byCompany.filter((r) => r.status === 'awaiting')
    case 'unsigned':
      return byCompany.filter(
        (r) => r.status === 'accepted' && r.document !== null && r.document.version < 2 && r.document.archived_at === null,
      )
    default:
      return byCompany
  }
})

const counts = computed(() => ({
  open: rows.value.filter((r) => r.status === 'awaiting').length,
  unsigned: rows.value.filter(
    (r) => r.status === 'accepted' && r.document !== null && r.document.version < 2 && r.document.archived_at === null,
  ).length,
}))

/** Who it went from, to whom. magacin is a real place in the books, so it is named. */
const movement = (r: Row) =>
  `${r.from_person?.full_name ?? 'magacin'} → ${r.to_person?.full_name ?? 'magacin'}`

async function load(): Promise<void> {
  loading.value = true
  const [handRes, compRes] = await Promise.all([
    supabase
      .from('asset_handovers')
      .select(
        'id, kind, status, created_at, company_id, started_by, counterparty_id, from_person_id, to_person_id, decline_reason, signed_by_starter_at, signed_by_counterparty_at, ' +
          'asset:assets(id, asset_tag, model), ' +
          'counterparty:people!asset_handovers_counterparty_id_fkey(full_name), ' +
          'starter:people!asset_handovers_started_by_fkey(full_name), ' +
          'from_person:people!asset_handovers_from_person_id_fkey(full_name), ' +
          'to_person:people!asset_handovers_to_person_id_fkey(full_name), ' +
          'document:documents(version, archived_at)',
      )
      .order('created_at', { ascending: false })
      .limit(300),
    supabase.from('companies').select('id, name').order('name'),
  ])
  loading.value = false
  if (handRes.error) {
    error.value = 'Could not load what has changed hands.'
    console.error('Handovers load failed:', handRes.error.message)
    return
  }
  rows.value = (handRes.data ?? []) as unknown as Row[]
  companies.value = (compRes.data ?? []) as { id: string; name: string }[]
}

onMounted(load)
</script>

<template>
  <div>
    <router-link class="back" :to="{ name: 'equipment' }">← Back to Equipment</router-link>
    <div class="eyebrow">Equipment</div>
    <h1 class="title">What changed hands</h1>
    <p class="sub">Every handover and return, newest first. Read-only — signing happens on the asset or on your own page.</p>

    <section class="card">
      <div class="card-head filters">
        <div class="tabs" role="tablist">
          <button type="button" role="tab" :aria-selected="state === 'open'" :class="{ on: state === 'open' }" @click="state = 'open'">
            Waiting on a signature<template v-if="counts.open"> ({{ counts.open }})</template>
          </button>
          <button type="button" role="tab" :aria-selected="state === 'unsigned'" :class="{ on: state === 'unsigned' }" @click="state = 'unsigned'">
            No signed paper copy<template v-if="counts.unsigned"> ({{ counts.unsigned }})</template>
          </button>
          <button type="button" role="tab" :aria-selected="state === 'all'" :class="{ on: state === 'all' }" @click="state = 'all'">
            Everything
          </button>
        </div>
        <CompanyFilter v-model="company" :companies="companies" all-label="Everywhere" />
      </div>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <div v-if="loading" class="empty">Loading…</div>
      <div v-else-if="!shown.length" class="empty">
        <template v-if="state === 'open'">Nothing is waiting on a signature.</template>
        <template v-else-if="state === 'unsigned'">Every settled handover has its signed copy on file.</template>
        <template v-else>Nothing has changed hands yet.</template>
      </div>

      <div v-for="r in shown" :key="r.id" class="row" :class="r.status">
        <div class="when">{{ r.created_at.slice(0, 10) }}</div>
        <div class="what">
          <strong>
            <router-link v-if="r.asset" :to="{ name: 'asset', params: { assetId: r.asset.id } }">{{ r.asset.asset_tag }}</router-link>
            <span v-else>—</span>
            <span class="muted"> · {{ movement(r) }}</span>
          </strong>
          <small>
            {{ handoverStatusLine(r, auth.personId, { starter: r.starter?.full_name ?? 'they', counterparty: r.counterparty?.full_name ?? 'they' }) }}
            <template v-if="r.asset?.model"> · {{ r.asset.model }}</template>
          </small>
          <small v-if="r.status === 'accepted' && r.document && r.document.version < 2 && r.document.archived_at === null" class="unsigned">
            Signed in the app, but the signed paper copy has not been uploaded.
          </small>
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
.back { display: inline-block; margin-bottom: 14px; font-size: 11px; color: var(--muted); text-decoration: none; }
.back:hover { text-decoration: underline; }
.title { margin: 4px 0 2px; }
.sub { margin: 0 0 20px; font-size: 13px; color: var(--muted); }
.filters { gap: 12px; flex-wrap: wrap; }
.tabs { display: flex; gap: 6px; flex-wrap: wrap; }
.tabs button { font: inherit; font-size: 11px; padding: 6px 12px; border: 1px solid var(--line); background: #fff; border-radius: 999px; cursor: pointer; color: var(--muted); }
.tabs button.on { border-color: var(--green); color: var(--green); font-weight: 600; }
.row { display: grid; grid-template-columns: 96px minmax(0, 1fr); gap: 14px; padding: 13px 24px; border-top: 1px solid #edf0eb; font-size: 12px; }
@media (max-width: 520px) { .row { grid-template-columns: 1fr; gap: 3px; } }
.row.awaiting { background: #fbf9ef; }
.row.declined, .row.cancelled { opacity: 0.7; }
.when { color: var(--muted); font-variant-numeric: tabular-nums; }
.what strong { display: block; font-weight: 550; }
.what strong a { color: inherit; text-decoration: none; }
.what strong a:hover { text-decoration: underline; }
.what small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.muted { font-weight: 400; color: var(--muted); }
.unsigned { color: #8a6d1f !important; }
</style>
