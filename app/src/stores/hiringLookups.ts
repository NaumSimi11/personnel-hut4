import { ref } from 'vue'
import { defineStore } from 'pinia'
import { supabase } from '@/lib/supabase'
import type { LookupRow, SubStatusRow } from '@/lib/hiringLabels'

/**
 * The hiring lookups — stages, statuses, sources — change a few times a year
 * but every hiring page used to re-read them on each open. They load once per
 * session here (egress: the project is on a metered plan); concurrent callers
 * share one request, and the Labels page calls `refresh()` after an edit.
 * Retired statuses and sources stay in the lists with `archived_at` set, so a
 * page can still name them; pickers filter on it.
 */
export type StageRow = { key: string; label: string; sort_order: number; is_terminal: boolean }
export type SourceRow = LookupRow & { archived_at: string | null }

export const useHiringLookupsStore = defineStore('hiringLookups', () => {
  const stages = ref<StageRow[]>([])
  const statuses = ref<SubStatusRow[]>([])
  const sources = ref<SourceRow[]>([])
  const loaded = ref(false)
  const error = ref<string | null>(null)
  let inflight: Promise<void> | null = null

  async function fetchAll(): Promise<void> {
    const [stagesRes, statusesRes, sourcesRes] = await Promise.all([
      supabase.from('application_stages').select('key, label, sort_order, is_terminal').order('sort_order'),
      supabase
        .from('application_sub_statuses')
        .select('key, stage_key, label, sort_order, outcome, archived_at')
        .order('stage_key')
        .order('sort_order'),
      supabase.from('candidate_sources').select('key, label, sort_order, archived_at').order('sort_order'),
    ])
    const failed = stagesRes.error ?? statusesRes.error ?? sourcesRes.error
    if (failed) {
      error.value = 'Could not load the hiring labels.'
      console.error('Hiring lookups load failed:', failed.message)
      return
    }
    stages.value = (stagesRes.data ?? []) as StageRow[]
    statuses.value = (statusesRes.data ?? []) as SubStatusRow[]
    sources.value = (sourcesRes.data ?? []) as SourceRow[]
    error.value = null
    loaded.value = true
  }

  function refresh(): Promise<void> {
    if (!inflight) {
      inflight = fetchAll().finally(() => {
        inflight = null
      })
    }
    return inflight
  }

  /** Load once per session; a failed load is tried again by the next caller. */
  async function ensure(): Promise<void> {
    if (loaded.value) return
    await refresh()
  }

  return { stages, statuses, sources, loaded, error, ensure, refresh }
})
