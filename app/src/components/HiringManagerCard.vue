<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import { hmPanel, type HmApplication } from '@/lib/hiringManager'
import type { SubStatusRow } from '@/lib/hiringLabels'

/**
 * The hiring manager's call on a candidate (0100): contact, contact in
 * future or do not contact, at Screening, on their own job. Everything else
 * on the page stays HR's; at Offer the HM follows along.
 */
const props = defineProps<{
  applicationId: string
  application: HmApplication
  rows: SubStatusRow[]
  isHiringManager: boolean
}>()
const emit = defineEmits<{ decided: [] }>()

const NOTE_MAX = 2000
const panel = computed(() => hmPanel(props.application, props.rows, props.isHiringManager))
const note = ref('')
const busyKey = ref<string | null>(null)
const error = ref<string | null>(null)

async function decide(key: string): Promise<void> {
  if (busyKey.value) return
  if (note.value.length > NOTE_MAX) {
    error.value = 'Keep the note to 2,000 characters or fewer.'
    return
  }
  error.value = null
  busyKey.value = key
  const { error: err } = await supabase.rpc('hm_set_status', {
    p_application_id: props.applicationId,
    p_sub_status_key: key,
    p_note: note.value.trim(),
  })
  busyKey.value = null
  if (err) {
    console.error('hm_set_status failed:', err.message)
    error.value = friendlyRecruitmentError(err.message)
    return
  }
  note.value = ''
  emit('decided')
}
</script>

<template>
  <section v-if="panel.mode !== 'hidden'" class="card hm-card" aria-label="Hiring manager decision" data-testid="hm-card">
    <div class="eyebrow">Your call as hiring manager</div>
    <template v-if="panel.mode === 'decide'">
      <p class="hint">Tell HR what to do with this candidate. HR takes it from there.</p>
      <div class="choices">
        <button
          v-for="c in panel.choices"
          :key="c.key"
          class="button"
          :class="{ secondary: !c.current }"
          type="button"
          :disabled="busyKey !== null || c.current"
          :aria-pressed="c.current"
          :data-testid="`hm-choice-${c.key}`"
          @click="decide(c.key)"
        >
          {{ busyKey === c.key ? 'Saving…' : c.label }}
        </button>
      </div>
      <label class="note-label" for="hm-note">Note for HR (optional)</label>
      <textarea id="hm-note" v-model="note" rows="2" :maxlength="NOTE_MAX" placeholder="Why — it lands on the timeline" />
    </template>
    <template v-else>
      <p class="hint" data-testid="hm-locked">{{ panel.reason }}</p>
      <p v-if="panel.current" class="hint">Status now: {{ panel.current }}</p>
    </template>
    <p v-if="error" class="error" role="alert">{{ error }}</p>
  </section>
</template>

<style scoped>
.hm-card { display: grid; gap: 8px; padding: 20px 24px; }
.choices { display: flex; flex-wrap: wrap; gap: 8px; }
.hint { margin: 0; color: var(--muted); }
.note-label { font-size: 0.85rem; color: var(--muted); }
textarea { width: 100%; }
.error { margin: 0; color: var(--red, #b42318); }
</style>
