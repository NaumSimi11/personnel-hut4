<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useDialogStore } from '@/stores/dialogs'
import { deliverNotifications } from '@/lib/notificationsApi'
import { CHECK_ANSWERS, answerInput, checkLine, type CheckAnswer } from '@/lib/equipmentCheck'

/**
 * The yearly equipment check on My workspace (24 Nov, 0130): every item the
 * person holds on an open check, with three answers. Shows nothing when
 * there is no open check for them.
 */
const props = defineProps<{ personId: string }>()

type Line = {
  id: string
  answer: CheckAnswer | null
  note: string | null
  check: { name: string; deadline: string; status: string } | null
  asset: { asset_tag: string; model: string | null; serial_number: string | null } | null
}

const dialogs = useDialogStore()
const lines = ref<Line[]>([])
const busyId = ref<string | null>(null)
const error = ref<string | null>(null)

const open = computed(() => lines.value.filter((l) => l.check?.status === 'open'))
const heading = computed(() => (open.value[0]?.check ? checkLine(open.value[0].check) : ''))
const left = computed(() => open.value.filter((l) => !l.answer).length)

async function load(): Promise<void> {
  const { data, error: err } = await supabase
    .from('equipment_check_items')
    .select('id, answer, note, check:equipment_checks(name, deadline, status), asset:assets(asset_tag, model, serial_number)')
    .eq('person_id', props.personId)
  if (err) {
    error.value = 'Could not load your equipment check.'
    console.error('Equipment check load failed:', err.message)
    return
  }
  lines.value = (data ?? []) as unknown as Line[]
}

function answerLabel(key: CheckAnswer | null): string {
  return CHECK_ANSWERS.find((a) => a.key === key)?.label ?? ''
}

async function answer(line: Line, key: CheckAnswer): Promise<void> {
  error.value = null
  let note = ''
  if (key !== 'have') {
    const reply = await dialogs.askReason({
      title: key === 'missing' ? 'You no longer have this item?' : 'What is wrong with it?',
      eyebrow: line.asset?.asset_tag ?? 'Equipment',
      hint: 'The person running the check sees your note and follows it up.',
      label: key === 'missing' ? 'What happened (returned, lost, given to a colleague…)' : 'What is wrong (damaged, details are wrong…)',
      confirmLabel: 'Send',
    })
    if (!reply) return
    note = reply.reason
  }
  const parsed = answerInput.safeParse({ answer: key, note })
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check your answer.'
    return
  }
  busyId.value = line.id
  const { error: err } = await supabase.rpc('answer_equipment_check', { p_item_id: line.id, p_answer: key, p_note: parsed.data.note })
  busyId.value = null
  if (err) {
    error.value = err.message || 'Could not save your answer.'
    console.error('answer_equipment_check failed:', err.message)
    return
  }
  if (key !== 'have') void deliverNotifications()
  await load()
}

onMounted(() => {
  void load()
})
</script>

<template>
  <div v-if="open.length" class="card check-card" data-testid="equipment-check-card">
    <div class="card-head">
      <div>
        <h2>Equipment check</h2>
        <p>{{ heading }}. {{ left ? `${left} item${left === 1 ? '' : 's'} still to confirm.` : 'All confirmed, thank you.' }}</p>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <ul class="lines">
      <li v-for="l in open" :key="l.id" class="line" :data-testid="`check-line-${l.id}`">
        <div class="what">
          <strong>{{ l.asset?.asset_tag ?? 'Item' }}</strong>
          <span>{{ [l.asset?.model, l.asset?.serial_number ? `S/N ${l.asset.serial_number}` : ''].filter(Boolean).join(' · ') }}</span>
          <small v-if="l.answer" class="answered">Your answer: {{ answerLabel(l.answer) }}{{ l.note ? ` — ${l.note}` : '' }}</small>
        </div>
        <div class="answers">
          <button
            v-for="a in CHECK_ANSWERS"
            :key="a.key"
            type="button"
            class="button small-btn"
            :class="{ secondary: l.answer !== a.key }"
            :disabled="busyId === l.id"
            :data-testid="`check-${a.key}`"
            @click="answer(l, a.key)"
          >
            {{ a.label }}
          </button>
        </div>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.check-card { border-color: var(--green, #2f6b4f); }
.in-card { margin: 12px 24px 0; }
.lines { list-style: none; margin: 0; padding: 0; }
.line { display: flex; gap: 12px; justify-content: space-between; align-items: center; flex-wrap: wrap; padding: 12px 24px; border-top: 1px solid #edf0eb; }
.what { display: flex; flex-direction: column; gap: 2px; min-width: 180px; }
.what span, .answered { font-size: 12px; color: var(--muted); }
.answers { display: flex; gap: 6px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 10px; }
</style>
