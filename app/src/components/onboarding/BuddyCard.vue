<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { deliverNotifications } from '@/lib/notificationsApi'
import { buddyLine, buddyOptionLabel, type BuddyOption } from '@/lib/buddy'

/**
 * Pick the new hire's buddy from the company's employees (audit C3). Saving
 * ticks "Buddy assigned" and sends the buddy a notice. Whoever may not pick
 * (no tasks.assign / tasks.complete, not the line's owner) sees who it is.
 */
const props = defineProps<{ planId: string; active: boolean }>()
const emit = defineEmits<{ changed: [] }>()

const current = ref<string | null>(null)
const options = ref<BuddyOption[]>([])
const canPick = ref(false)
const choice = ref('')
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

async function load(): Promise<void> {
  error.value = null
  const { data, error: err } = await supabase
    .from('plans')
    .select('buddy_id, buddy:people!plans_buddy_id_fkey(full_name)')
    .eq('id', props.planId)
    .maybeSingle()
  if (err) {
    error.value = 'Could not load the buddy.'
    console.error('Buddy load failed:', err.message)
    return
  }
  const row = data as { buddy_id: string | null; buddy: { full_name: string } | null } | null
  current.value = row?.buddy?.full_name ?? null
  choice.value = row?.buddy_id ?? ''
  const opts = await supabase.rpc('buddy_options', { p_plan_id: props.planId })
  canPick.value = !opts.error
  options.value = (opts.data ?? []) as BuddyOption[]
}

async function save(): Promise<void> {
  if (!choice.value) return
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err } = await supabase.rpc('set_onboarding_buddy', { p_plan_id: props.planId, p_buddy_id: choice.value })
  busy.value = false
  if (err) {
    error.value = err.message || 'Could not save the buddy.'
    console.error('set_onboarding_buddy failed:', err.message)
    return
  }
  void deliverNotifications()
  await load()
  notice.value = `${current.value ?? 'The buddy'} is the buddy and has been told.`
  emit('changed')
}

onMounted(() => {
  void load()
})
</script>

<template>
  <div class="card" data-testid="buddy-card">
    <div class="card-head">
      <div>
        <h2>Buddy</h2>
        <p>A colleague who shows the new hire around and answers questions in the first weeks.</p>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <div class="foot">
      <small data-testid="buddy-current">{{ buddyLine(current) }}</small>
      <div v-if="canPick && active" class="actions">
        <select v-model="choice" aria-label="Buddy" data-testid="buddy-select">
          <option value="" disabled>Pick a colleague</option>
          <option v-for="o in options" :key="o.id" :value="o.id">{{ buddyOptionLabel(o) }}</option>
        </select>
        <button type="button" class="button small-btn" :disabled="busy || !choice" data-testid="buddy-save" @click="save">
          {{ busy ? 'Saving…' : current ? 'Change buddy' : 'Set buddy' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.in-card, .notice { margin: 12px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.foot { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding: 12px 24px 14px; border-top: 1px solid #edf0eb; }
.foot small { font-size: 12px; color: var(--muted); }
.actions { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.actions select { border: 1px solid #dce3d7; padding: 7px 10px; font-size: 11px; background: #fff; max-width: 260px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
