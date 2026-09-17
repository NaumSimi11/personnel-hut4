<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { tidyKit } from '@/lib/equipment'

/**
 * Settings → Starter kit (plan 049): what every starter in this company
 * gets. The holding's list shows until the company sets its own; an empty
 * own list falls back to the holding's. it.assign here, or admin.
 */
const props = defineProps<{ companyId: string; companyName: string }>()

const auth = useAuthStore()
const items = ref<string[]>([])
const own = ref(false)
const draft = ref('')
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const canEdit = computed(() => auth.can(props.companyId, 'it.assign'))

async function load(): Promise<void> {
  loading.value = true
  const { data, error: err } = await supabase.rpc('starter_kit', { p_company_id: props.companyId })
  loading.value = false
  if (err) {
    error.value = 'Could not load the starter kit.'
    console.error('Starter kit load failed:', err.message)
    return
  }
  const result = data as { items: string[]; own: boolean }
  items.value = result.items ?? []
  own.value = result.own === true
}

async function save(next: string[]): Promise<void> {
  busy.value = true
  error.value = null
  notice.value = null
  const { data, error: err } = await supabase.rpc('set_starter_kit', { p_company_id: props.companyId, p_items: tidyKit(next) })
  busy.value = false
  if (err) {
    error.value = err.code === '42501' ? err.message : 'Could not save the starter kit.'
    console.error('Starter kit save failed:', err.message)
    return
  }
  const result = data as { items: string[] }
  items.value = result.items
  own.value = result.items.length > 0
  if (!own.value) await load()
  notice.value = own.value ? `${props.companyName}'s starter kit saved.` : 'Back to the holding default.'
}

function add(): void {
  const value = draft.value.trim()
  if (value.length < 2) return
  draft.value = ''
  void save([...items.value, value])
}

function remove(item: string): void {
  void save(items.value.filter((i) => i !== item))
}

watch(() => props.companyId, load)
onMounted(load)
</script>

<template>
  <div class="card" data-testid="starter-kit-panel">
    <div class="card-head">
      <div>
        <h2>Starter kit</h2>
        <p>What every new starter gets. Each hire's checklist opens an IT request with these items; ticking them all completes "Starter kit issued".</p>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice">{{ notice }}</output>
    <div v-if="loading" class="empty">Loading…</div>
    <div v-else class="body">
      <p class="source" data-testid="kit-source">{{ own ? `${companyName}'s own kit.` : 'The holding default — add an item to make this company\'s own list.' }}</p>
      <div class="chips">
        <span v-for="item in items" :key="item" class="chip" :data-testid="`kit-item`">
          {{ item }}
          <button v-if="canEdit" type="button" class="x" :aria-label="`Remove ${item}`" :disabled="busy" @click="remove(item)">×</button>
        </span>
        <span v-if="!items.length" class="muted">Nothing yet.</span>
      </div>
      <form v-if="canEdit" class="add" novalidate @submit.prevent="add">
        <input id="kit-new" v-model="draft" maxlength="80" placeholder="Add an item, e.g. Headset" aria-label="New kit item" />
        <button class="button secondary small-btn" type="submit" :disabled="busy">Add</button>
      </form>
    </div>
  </div>
</template>

<style scoped>
.in-card, .notice { margin: 14px 24px 0; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.body { padding: 12px 24px 18px; }
.source { margin: 0 0 10px; font-size: 11px; color: var(--muted); }
.chips { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 12px; }
.chip { display: inline-flex; align-items: center; gap: 6px; border: 1px solid var(--line); background: #fff; font-size: 12px; padding: 5px 10px; border-radius: 999px; }
.x { border: 0; background: none; color: var(--muted); cursor: pointer; font-size: 14px; line-height: 1; padding: 0; }
.x:hover { color: var(--red); }
.muted { font-size: 12px; color: var(--muted); }
.add { display: flex; gap: 8px; max-width: 420px; }
.add input { flex: 1; border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
