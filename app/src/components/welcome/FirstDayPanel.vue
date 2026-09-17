<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import type { Json } from '@/types/database'

/**
 * Settings → First day (plan 050): where to come, when, who to ask for,
 * what to bring — the lines the welcome note carries. The holding's text
 * shows until the company writes its own. tasks.assign here, or admin.
 */
const props = defineProps<{ companyId: string; companyName: string }>()

type Details = { where: string; when: string; ask_for: string; bring: string }

const auth = useAuthStore()
const form = ref<Details>({ where: '', when: '', ask_for: '', bring: '' })
const own = ref(false)
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const canEdit = computed(() => auth.can(props.companyId, 'tasks.assign'))

async function load(): Promise<void> {
  loading.value = true
  const { data, error: err } = await supabase.rpc('first_day_details', { p_company_id: props.companyId })
  loading.value = false
  if (err) {
    error.value = 'Could not load the first-day details.'
    console.error('First-day load failed:', err.message)
    return
  }
  const result = data as { details: Partial<Details>; own: boolean }
  form.value = { where: result.details.where ?? '', when: result.details.when ?? '', ask_for: result.details.ask_for ?? '', bring: result.details.bring ?? '' }
  own.value = result.own
}

async function save(): Promise<void> {
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err } = await supabase.rpc('set_first_day_details', { p_company_id: props.companyId, p: form.value as unknown as Json })
  busy.value = false
  if (err) {
    error.value = err.code === '42501' ? err.message : 'Could not save the first-day details.'
    return
  }
  notice.value = 'First-day details saved.'
  await load()
}

watch(() => props.companyId, load)
onMounted(load)
</script>

<template>
  <div class="card" data-testid="first-day-panel">
    <div class="card-head">
      <div>
        <h2>First day</h2>
        <p>What the welcome note tells a new starter about their first day.</p>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <div v-if="loading" class="empty">Loading…</div>
    <form v-else class="body" novalidate @submit.prevent="save">
      <p class="source">{{ own ? `${companyName}'s own details.` : 'The holding default — save to make this company\'s own.' }}</p>
      <div class="grid">
        <div class="field"><label for="fd-where">Where to come</label><input id="fd-where" v-model="form.where" maxlength="300" :disabled="!canEdit" placeholder="e.g. Reception, 2nd floor, Partizanska 1" /></div>
        <div class="field"><label for="fd-when">When</label><input id="fd-when" v-model="form.when" maxlength="120" :disabled="!canEdit" placeholder="e.g. 09:00" /></div>
        <div class="field"><label for="fd-ask">Who to ask for</label><input id="fd-ask" v-model="form.ask_for" maxlength="120" :disabled="!canEdit" placeholder="e.g. Ana at reception" /></div>
        <div class="field"><label for="fd-bring">What to bring</label><input id="fd-bring" v-model="form.bring" maxlength="300" :disabled="!canEdit" placeholder="e.g. ID card, bank details" /></div>
      </div>
      <div v-if="canEdit" class="actions"><button class="button" type="submit" :disabled="busy">{{ busy ? 'Saving…' : 'Save' }}</button></div>
    </form>
  </div>
</template>

<style scoped>
.in-card, .notice { margin: 12px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.body { padding: 12px 24px 18px; }
.source { margin: 0 0 10px; font-size: 11px; color: var(--muted); }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
@media (max-width: 620px) { .grid { grid-template-columns: 1fr; } }
.actions { display: flex; justify-content: flex-end; }
</style>
