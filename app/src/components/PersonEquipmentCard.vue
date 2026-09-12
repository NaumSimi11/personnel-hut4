<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { assetStatusLabel, itRequestStatusLabel } from '@/lib/equipment'

/**
 * What one person holds and what IT is doing for them (plan 029): open
 * assignments (reserved or issued) and IT requests that are not closed.
 * Read-only; the viewer is the person or holds it.view in a company they
 * have employment with. RLS on both tables is the gate.
 */

type Company = { id: string; name: string }
const props = withDefaults(defineProps<{ personId: string; companies: Company[]; title?: string }>(), { title: 'Equipment' })

type Held = {
  id: string
  reserved_at: string | null
  issued_at: string | null
  returned_at: string | null
  asset: { asset_tag: string; type_key: string; model: string | null; status: string; company_id: string } | null
}
type Request = { id: string; title: string; status: string; company_id: string; requested_systems: unknown; blocked_reason: string | null }

const auth = useAuthStore()
const visible = computed(
  () => auth.isAdmin || auth.personId === props.personId || props.companies.some((c) => auth.can(c.id, 'it.view')),
)

const loading = ref(true)
const error = ref<string | null>(null)
const held = ref<Held[]>([])
const requests = ref<Request[]>([])
const types = ref<Record<string, string>>({})

const companyName = (id: string) => props.companies.find((c) => c.id === id)?.name ?? ''
const systemsOf = (r: Request) => (Array.isArray(r.requested_systems) ? r.requested_systems.filter((s): s is string => typeof s === 'string') : [])

async function load(): Promise<void> {
  if (!visible.value) {
    loading.value = false
    return
  }
  loading.value = true
  error.value = null
  const [heldRes, reqRes, typeRes] = await Promise.all([
    supabase
      .from('asset_assignments')
      .select('id, reserved_at, issued_at, returned_at, asset:assets(asset_tag, type_key, model, status, company_id)')
      .eq('person_id', props.personId)
      .is('returned_at', null),
    supabase
      .from('it_requests')
      .select('id, title, status, company_id, requested_systems, blocked_reason')
      .eq('person_id', props.personId)
      .not('status', 'in', '("done","cancelled")'),
    supabase.from('asset_types').select('key, label'),
  ])
  loading.value = false
  if (heldRes.error || reqRes.error) {
    error.value = 'Could not load equipment.'
    console.error('Person equipment load failed:', heldRes.error?.message ?? reqRes.error?.message)
    return
  }
  held.value = (heldRes.data ?? []) as unknown as Held[]
  requests.value = (reqRes.data ?? []) as Request[]
  types.value = Object.fromEntries((typeRes.data ?? []).map((t) => [t.key, t.label]))
}

onMounted(load)
watch(() => `${props.personId}|${props.companies.map((c) => c.id).join(',')}`, () => load())
</script>

<template>
  <div v-if="visible && (loading || error || held.length || requests.length)" class="card">
    <div class="card-head">
      <div>
        <h2>{{ title }}</h2>
        <p>Equipment on hand and open IT work.</p>
      </div>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="error" class="error" role="alert">{{ error }}</div>
      <div v-for="h in held" :key="h.id" class="equipment-row">
        <div class="row-text">
          <strong>{{ h.asset?.asset_tag }} <span class="muted">· {{ types[h.asset?.type_key ?? ''] ?? h.asset?.type_key }}<template v-if="h.asset?.model"> · {{ h.asset.model }}</template></span></strong>
          <small>
            {{ h.issued_at ? `issued ${h.issued_at.slice(0, 10)}` : `reserved ${h.reserved_at?.slice(0, 10) ?? ''}` }}
            <template v-if="h.asset"> · {{ assetStatusLabel(h.asset.status) }}</template>
            <template v-if="h.asset && companies.length > 1"> · {{ companyName(h.asset.company_id) }}</template>
          </small>
        </div>
      </div>
      <div v-for="r in requests" :key="r.id" class="equipment-row it">
        <div class="row-text">
          <strong>{{ r.title }}</strong>
          <small>
            IT request · {{ itRequestStatusLabel(r.status) }}
            <template v-if="systemsOf(r).length"> · {{ systemsOf(r).join(', ') }}</template>
            <template v-if="r.blocked_reason"> · {{ r.blocked_reason }}</template>
          </small>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.equipment-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.muted { font-weight: 400; color: var(--muted); }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
</style>
