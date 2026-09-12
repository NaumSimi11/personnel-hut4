<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { actionLabel, entityLabel, summarizeChange } from '@/lib/activity'

/**
 * A company's audit trail (plan 030), read from activity_log under its own
 * policies: admins and access.manage see everything in the company,
 * recruitment holders the recruitment entities. Sensitive content never
 * reaches the log (0018/0020), so what is shown is what the row carries.
 */

const props = defineProps<{ companyId: string }>()

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
const entityFilter = ref('')
const search = ref('')

const entityTypes = computed(() => [...new Set(entries.value.map((e) => e.entity_type))].sort())
const rows = computed(() =>
  entries.value
    .map((e) => ({ ...e, summary: summarizeChange(e.action, e.before, e.after) }))
    .filter((e) => !entityFilter.value || e.entity_type === entityFilter.value)
    .filter((e) => {
      const needle = search.value.trim().toLowerCase()
      if (!needle) return true
      const hay = [entityLabel(e.entity_type), actionLabel(e.action), actorName(e.actor_person_id), ...e.summary].join(' ').toLowerCase()
      return hay.includes(needle)
    }),
)

function actorName(id: string | null): string {
  return id ? (names.value[id] ?? 'someone') : 'system'
}

function when(at: string): string {
  return new Date(at).toLocaleString()
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const { data, error: err } = await supabase
    .from('activity_log')
    .select('id, at, actor_person_id, entity_type, entity_id, action, before, after')
    .eq('company_id', props.companyId)
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
  if (ids.length) {
    const { data: people, error: peopleErr } = await supabase.from('people').select('id, full_name').in('id', ids)
    if (peopleErr) {
      error.value = 'Actor names could not be loaded.'
      console.error('Activity actor lookup failed:', peopleErr.message)
    }
    names.value = Object.fromEntries((people ?? []).map((p) => [p.id, p.full_name]))
  }
  loading.value = false
}

onMounted(load)
watch(() => props.companyId, load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Activity</h2>
        <p>Who changed what, most recent first (last {{ LIMIT }}). Restricted content is never in the trail.</p>
      </div>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="error" class="error" role="alert">{{ error }}</div>
      <div class="filters">
        <select id="activity-entity" v-model="entityFilter" aria-label="Entity">
          <option value="">All entities</option>
          <option v-for="t in entityTypes" :key="t" :value="t">{{ entityLabel(t) }}</option>
        </select>
        <input id="activity-search" v-model="search" placeholder="Find in the trail" aria-label="Search" />
        <span class="count">{{ rows.length }} of {{ entries.length }}</span>
      </div>
      <div v-if="!rows.length" class="empty">Nothing recorded yet.</div>
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
.count { font-size: 11px; color: var(--muted); }
.activity-row { display: flex; gap: 14px; padding: 11px 24px; border-top: 1px solid #edf0eb; }
.when { font-size: 10px; color: var(--muted); white-space: nowrap; padding-top: 2px; min-width: 110px; }
.row-text { flex: 1; min-width: 0; }
.row-text strong { display: block; font-size: 12px; font-weight: 500; }
.entity { font-weight: 600; }
.actor { font-weight: 600; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 3px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
</style>
