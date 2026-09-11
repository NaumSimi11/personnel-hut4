<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { acknowledgementState, signedPolicyUrl, type AcknowledgementLite, type PolicyRow } from '@/lib/policies'

/**
 * The person's policies (plan 028): every published policy in their scope
 * (RLS: holding-wide, or a company they are in), with the acknowledgement
 * state per current version and a one-click acknowledgement.
 */

const auth = useAuthStore()
const loading = ref(true)
const busyId = ref<string | null>(null)
const error = ref<string | null>(null)
const policies = ref<(PolicyRow & { company: { name: string } | null })[]>([])
const acks = ref<AcknowledgementLite[]>([])

const state = (p: PolicyRow) => acknowledgementState(p, acks.value)
const sorted = computed(() =>
  [...policies.value].sort((a, b) => Number(state(a) === 'acknowledged') - Number(state(b) === 'acknowledged') || a.title.localeCompare(b.title)),
)
const pendingCount = computed(() => policies.value.filter((p) => state(p) !== 'acknowledged').length)

async function load(): Promise<void> {
  if (!auth.personId) {
    loading.value = false
    return
  }
  loading.value = true
  error.value = null
  const [polRes, ackRes] = await Promise.all([
    supabase.from('policies').select('*, company:companies(name)').eq('status', 'published').order('title'),
    supabase.from('policy_acknowledgements').select('policy_id, version').eq('person_id', auth.personId),
  ])
  if (polRes.error || ackRes.error) {
    error.value = 'Could not load policies.'
    console.error('My policies load failed:', polRes.error?.message ?? ackRes.error?.message)
    loading.value = false
    return
  }
  policies.value = (polRes.data ?? []) as typeof policies.value
  acks.value = ackRes.data ?? []
  loading.value = false
}

async function acknowledge(policy: PolicyRow): Promise<void> {
  busyId.value = policy.id
  error.value = null
  const { error: err } = await supabase.rpc('acknowledge_policy', { p_policy_id: policy.id })
  busyId.value = null
  if (err) {
    error.value = err.message
    console.error('Policy acknowledgement failed:', err.message)
    return
  }
  await load()
}

async function open(policy: PolicyRow): Promise<void> {
  if (!policy.storage_path) return
  const tab = window.open('', '_blank')
  try {
    const url = await signedPolicyUrl(policy.storage_path)
    if (tab) tab.location.href = url
  } catch (e) {
    tab?.close()
    error.value = e instanceof Error ? e.message : 'Could not open the policy.'
  }
}

onMounted(load)
</script>

<template>
  <div v-if="policies.length || loading" class="card">
    <div class="card-head">
      <div>
        <h2>Policies</h2>
        <p>{{ pendingCount ? `${pendingCount} to read and acknowledge.` : 'You are up to date.' }}</p>
      </div>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="error" class="error" role="alert">{{ error }}</div>
      <div v-for="p in sorted" :key="p.id" class="policy-row" :class="state(p)">
        <div class="row-text">
          <strong>{{ p.title }} <span class="version">v{{ p.version }}</span></strong>
          <small>
            {{ p.company?.name ?? 'Holding-wide' }}
            <template v-if="state(p) === 'acknowledged'"> · Acknowledged</template>
            <template v-else-if="state(p) === 'outdated'"> · New version — please read and acknowledge again</template>
            <template v-else> · Please read and acknowledge</template>
            <template v-if="p.summary"> · {{ p.summary }}</template>
          </small>
        </div>
        <div class="actions">
          <button v-if="p.storage_path" class="button secondary small-btn" type="button" @click="open(p)">Open</button>
          <button
            v-if="state(p) !== 'acknowledged'"
            class="button small-btn"
            type="button"
            :disabled="busyId === p.id"
            @click="acknowledge(p)"
          >
            I have read this
          </button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.policy-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.policy-row.pending, .policy-row.outdated { background: #fbf7ea; }
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 10px; color: var(--muted); margin-top: 4px; }
.version { font-size: 10px; font-weight: 600; color: var(--muted); margin-left: 4px; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
</style>
