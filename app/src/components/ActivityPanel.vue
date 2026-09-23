<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import {
  actionLabel,
  activityCount,
  entityLabel,
  periodStart,
  summarizeChange,
  ANY_ACTOR,
  DEFAULT_PERIOD,
  PERIOD_LABELS,
  SYSTEM_ACTOR,
  type ActivityPeriod,
  type ActorChoice,
} from '@/lib/activity'

/**
 * A company's audit trail (plan 030), read from activity_log under its own
 * policies: admins and access.manage see everything in the company,
 * recruitment holders the recruitment entities. Sensitive content never
 * reaches the log (0018/0020), so what is shown is what the row carries.
 *
 * Plan 059 made it readable. It used to load the 200 most recent rows and
 * filter those in the page; after the Zoho import wrote some 24,000 rows in a
 * day, those 200 were all import, so choosing an entity or searching for a
 * colleague searched inside the import and found nothing — Ivana's 55 real
 * changes sat behind Naum's 12,902 imported ones. Every filter below is now
 * part of the query, so each one goes and fetches the rows it describes.
 */

const props = defineProps<{ companyId: string; companyKind?: string }>()

type Entry = {
  id: number
  at: string
  actor_person_id: string | null
  entity_type: string
  entity_id: string | null
  action: string
  before: Record<string, unknown> | null
  after: Record<string, unknown> | null
}

const LIMIT = 200

const loading = ref(true)
const error = ref<string | null>(null)
const entries = ref<Entry[]>([])
const names = ref<Record<string, string>>({})
const actors = ref<ActorChoice[]>([])
const entityTypes = ref<string[]>([])

const period = ref<ActivityPeriod>(DEFAULT_PERIOD)
const actorFilter = ref<string>(ANY_ACTOR)
const entityFilter = ref('')
const search = ref('')

/**
 * The holding's own page also shows what belongs to no single company —
 * candidates and their files are holding-wide (0067), which is where most of
 * the trail lives and where none of it could be seen before. RLS still
 * decides: those rows are readable by admins only.
 */
const holdingWide = computed(() => props.companyKind === 'holding')

/**
 * The part of a PostgREST chain these filters need. The client's own generics
 * lose the row type through a helper, and the shape being narrow here is the
 * point: this function may filter and order, and nothing else.
 */
type Answer = { data: unknown[] | null; error: { message: string } | null }
type Filterable = {
  or: (filter: string) => Filterable
  eq: (column: string, value: unknown) => Filterable
  is: (column: string, value: unknown) => Filterable
  gte: (column: string, value: unknown) => Filterable
  order: (column: string, options: { ascending: boolean }) => Filterable
  limit: (n: number) => PromiseLike<Answer>
  range: (from: number, to: number) => PromiseLike<Answer>
}

/** Everything but the free-text search, which reads what the query returned. */
function scoped(q: Filterable): Filterable {
  let out = holdingWide.value ? q.or(`company_id.eq.${props.companyId},company_id.is.null`) : q.eq('company_id', props.companyId)
  const from = periodStart(period.value)
  if (from) out = out.gte('at', from)
  if (entityFilter.value) out = out.eq('entity_type', entityFilter.value)
  if (actorFilter.value === SYSTEM_ACTOR) out = out.is('actor_person_id', null)
  else if (actorFilter.value) out = out.eq('actor_person_id', actorFilter.value)
  return out
}

const rows = computed(() =>
  entries.value
    .map((e) => ({ ...e, summary: summarizeChange(e.action, e.before, e.after) }))
    .filter((e) => {
      const needle = search.value.trim().toLowerCase()
      if (!needle) return true
      const hay = [entityLabel(e.entity_type), actionLabel(e.action), actorName(e.actor_person_id), ...e.summary].join(' ').toLowerCase()
      return hay.includes(needle)
    }),
)

const heading = computed(() => activityCount(rows.value.length, LIMIT))

function actorName(id: string | null): string {
  return id ? (names.value[id] ?? 'someone') : 'system'
}

function when(at: string): string {
  return new Date(at).toLocaleString()
}

/**
 * Who has acted here, and on what — from the whole trail, not from a window
 * of it. `activity_choices` (0073) runs under the same row policies as the
 * list itself, so the dropdowns offer exactly what the caller could reach.
 * Deliberately not narrowed by the period: pick the person first, then widen
 * or narrow the dates around them.
 */
async function loadChoices(): Promise<void> {
  const { data, error: err } = await supabase.rpc('activity_choices', {
    p_company_id: props.companyId,
    p_holding_wide: holdingWide.value,
  })
  if (err) {
    console.error('Activity choices failed:', err.message)
    return
  }
  const choices = (data ?? {}) as { actors?: { id: string; full_name: string | null }[]; entity_types?: string[] }
  entityTypes.value = choices.entity_types ?? []
  const found = choices.actors ?? []
  names.value = {
    ...names.value,
    ...Object.fromEntries(found.filter((a) => a.full_name).map((a) => [a.id, a.full_name as string])),
  }
  actors.value = found.map((a) => ({ id: a.id, full_name: a.full_name ?? 'someone' }))
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await scoped(
    supabase
      .from('activity_log')
      .select('id, at, actor_person_id, entity_type, entity_id, action, before, after') as unknown as Filterable,
  )
    .order('at', { ascending: false })
    .limit(LIMIT)
  if (err) {
    error.value = 'Could not load the activity history.'
    console.error('Activity load failed:', err.message)
    loading.value = false
    return
  }
  entries.value = (data ?? []) as Entry[]
  const ids = [...new Set(entries.value.map((e) => e.actor_person_id).filter((id): id is string => !!id))]
  const missing = ids.filter((id) => !names.value[id])
  if (missing.length) {
    const { data: people, error: peopleErr } = await supabase.from('people').select('id, full_name').in('id', missing)
    if (peopleErr) {
      error.value = 'Actor names could not be loaded.'
      console.error('Activity actor lookup failed:', peopleErr.message)
    }
    names.value = { ...names.value, ...Object.fromEntries((people ?? []).map((p) => [p.id, p.full_name])) }
  }
  loading.value = false
}

onMounted(async () => {
  await loadChoices()
  await load()
})
watch(() => props.companyId, async () => {
  await loadChoices()
  await load()
})
// The dropdowns cover the whole trail, so only the list is fetched again.
watch([period, actorFilter, entityFilter], load)

function clearFilters(): void {
  actorFilter.value = ANY_ACTOR
  entityFilter.value = ''
  search.value = ''
}
const filtered = computed(() => actorFilter.value !== ANY_ACTOR || entityFilter.value !== '' || search.value !== '')
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Activity</h2>
        <p>
          Who changed what, most recent first — {{ heading }}. Restricted content is never in the trail.
          <template v-if="holdingWide"> Includes what belongs to the holding rather than to one company.</template>
        </p>
      </div>
    </div>
    <div v-if="error" class="error" role="alert">{{ error }}</div>
    <div class="filters">
      <select v-model="period" aria-label="Period" data-testid="activity-period">
        <option v-for="(label, key) in PERIOD_LABELS" :key="key" :value="key">{{ label }}</option>
      </select>
      <select v-model="actorFilter" aria-label="Who" data-testid="activity-actor">
        <option :value="ANY_ACTOR">Anyone</option>
        <option :value="SYSTEM_ACTOR">The system itself</option>
        <option v-for="a in actors" :key="a.id" :value="a.id">{{ a.full_name }}</option>
      </select>
      <select id="activity-entity" v-model="entityFilter" aria-label="Entity" data-testid="activity-entity">
        <option value="">Everything</option>
        <option v-for="t in entityTypes" :key="t" :value="t">{{ entityLabel(t) }}</option>
      </select>
      <input v-model="search" placeholder="Find in what is shown" aria-label="Find in what is shown" />
      <button v-if="filtered" class="linkish" type="button" data-testid="activity-clear" @click="clearFilters">Clear</button>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="!rows.length" class="empty" data-testid="activity-empty">
        Nothing changed here in this period.<template v-if="filtered"> Try clearing the filters, or widen the period.</template>
      </div>
      <div v-for="e in rows" :key="e.id" class="activity-row">
        <div class="when">{{ when(e.at) }}</div>
        <div class="row-text">
          <strong>
            <span class="entity">{{ entityLabel(e.entity_type) }}</span> {{ actionLabel(e.action) }} by
            <span class="actor">{{ actorName(e.actor_person_id) }}</span>
          </strong>
          <small v-if="e.summary.length">{{ e.summary.join(' · ') }}</small>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.filters { display: flex; gap: 10px; align-items: center; padding: 14px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.filters select, .filters input { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
.filters input { flex: 1; min-width: 160px; }
.linkish { background: none; border: 0; padding: 0; font: inherit; font-size: 11px; color: var(--muted); cursor: pointer; text-decoration: underline; }
.note { margin: 0; padding: 0 24px 12px; font-size: 11px; color: var(--muted); line-height: 1.6; }
.activity-row { display: flex; gap: 14px; padding: 11px 24px; border-top: 1px solid #edf0eb; }
.when { font-size: 11px; color: var(--muted); white-space: nowrap; padding-top: 2px; min-width: 110px; }
.row-text { flex: 1; min-width: 0; }
.row-text strong { display: block; font-size: 12px; font-weight: 500; }
.entity { font-weight: 600; }
.actor { font-weight: 600; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
</style>
