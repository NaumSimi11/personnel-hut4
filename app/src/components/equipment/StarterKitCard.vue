<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { kitItems, kitProgress, type KitItem } from '@/lib/equipment'
import { generateDocuments } from '@/lib/notificationsApi'

/**
 * The starter kit on an onboarding checklist (plan 049): the items the
 * company hands every starter, as checkboxes IT ticks as issued, each
 * optionally naming a registered asset (which is then reserved and issued
 * to the person in one go), plus the extra item this hire needs. When
 * every item is issued the request is done and the "Starter kit issued"
 * line ticks itself.
 */
const props = defineProps<{ planId: string; personId: string; companyId: string }>()
// `present` lets the page know whether this card rendered anything: with no
// starter-kit request there is no card, and a nav link to it would go nowhere.
const emit = defineEmits<{ changed: []; present: [present: boolean] }>()

type Request = { id: string; status: string; requested_systems: unknown }
type AssetOption = { id: string; asset_tag: string; model: string | null; company_id: string | null }

const auth = useAuthStore()
const request = ref<Request | null>(null)
const assets = ref<AssetOption[]>([])
const picks = ref<Record<number, string>>({})
const extra = ref('')
const loading = ref(true)
const busyIndex = ref<number | null>(null)
const error = ref<string | null>(null)

const items = computed<KitItem[]>(() => kitItems(request.value?.requested_systems))
const bar = computed(() => kitProgress(items.value))
const canIssue = computed(() => auth.can(props.companyId, 'it.assign') || auth.can(props.companyId, 'it.complete'))
const canAdd = computed(() => auth.can(props.companyId, 'it.assign') || auth.can(props.companyId, 'tasks.assign'))
const assetLabel = (id: string | null) => (id ? (assets.value.find((a) => a.id === id)?.asset_tag ?? 'asset') : null)

async function load(): Promise<void> {
  loading.value = true
  const [reqRes, assetRes] = await Promise.all([
    supabase
      .from('it_requests')
      .select('id, status, requested_systems, plan_task_id')
      .eq('person_id', props.personId)
      .eq('kind', 'onboarding')
      .not('plan_task_id', 'is', null)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase.from('assets').select('id, asset_tag, model, company_id').eq('status', 'available').order('asset_tag'),
  ])
  loading.value = false
  if (reqRes.error) {
    error.value = 'Could not load the starter kit.'
    console.error('Starter kit load failed:', reqRes.error.message)
    emit('present', false)
    return
  }
  request.value = (reqRes.data as Request | null) ?? null
  emit('present', request.value !== null)
  // Only assets that may go to this person: the pool, or this company's.
  assets.value = ((assetRes.data ?? []) as AssetOption[]).filter((a) => a.company_id === null || a.company_id === props.companyId)
}

async function issue(index: number): Promise<void> {
  if (!request.value) return
  error.value = null
  busyIndex.value = index
  const named = picks.value[index] || undefined
  const { error: err } = await supabase.rpc('issue_kit_item', { p_request_id: request.value.id, p_index: index, p_asset_id: named })
  busyIndex.value = null
  if (err) {
    error.value = err.message
    return
  }
  // Naming an asset issued it, which queued the handover form.
  if (named) void generateDocuments()
  await load()
  emit('changed')
}

async function addExtra(): Promise<void> {
  if (!request.value || extra.value.trim().length < 2) return
  error.value = null
  const { error: err } = await supabase.rpc('add_kit_item', { p_request_id: request.value.id, p_item: extra.value.trim() })
  if (err) {
    error.value = err.message
    return
  }
  extra.value = ''
  await load()
}

watch(() => props.personId, load)
onMounted(load)
</script>

<template>
  <div v-if="!loading && request" class="card" data-testid="starter-kit-card">
    <div class="card-head">
      <div>
        <h2>Starter kit</h2>
        <p>{{ bar.issued }} of {{ bar.total }} issued. Tick an item as it is handed over; name a registered asset to issue it at the same time.</p>
      </div>
      <span class="badge" :class="request.status === 'done' ? 'green' : 'blue'">{{ request.status === 'done' ? 'Issued' : request.status === 'in_progress' ? 'In progress' : 'Open' }}</span>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <div v-for="(item, i) in items" :key="i" class="item" :class="{ done: item.issued_at }" :data-testid="`kit-line-${i}`">
      <label class="tick">
        <input type="checkbox" :checked="item.issued_at !== null" :disabled="item.issued_at !== null || !canIssue || busyIndex === i" :aria-label="`${item.item} issued`" @change="issue(i)" />
      </label>
      <div class="text">
        <strong>{{ item.item }}</strong>
        <small v-if="item.issued_at">Issued {{ item.issued_at.slice(0, 10) }}<template v-if="item.asset_id"> · {{ assetLabel(item.asset_id) ?? 'registered asset' }}</template></small>
        <small v-else-if="canIssue" class="pick">
          <select v-model="picks[i]" :aria-label="`Asset for ${item.item}`">
            <option value="">No registered asset</option>
            <option v-for="a in assets" :key="a.id" :value="a.id">{{ a.asset_tag }}<template v-if="a.model"> · {{ a.model }}</template>{{ a.company_id === null ? ' (pool)' : '' }}</option>
          </select>
        </small>
      </div>
    </div>
    <form v-if="canAdd && request.status !== 'done'" class="add" novalidate @submit.prevent="addExtra">
      <input v-model="extra" maxlength="80" placeholder="Something extra this hire needs" aria-label="Extra kit item" />
      <button class="button secondary small-btn" type="submit">Add item</button>
    </form>
  </div>
</template>

<style scoped>
.in-card { margin: 12px 24px 0; }
.item { display: flex; align-items: flex-start; gap: 12px; padding: 10px 24px; border-top: 1px solid #edf0eb; }
.item.done strong { color: var(--muted); text-decoration: line-through; }
.tick input { width: 18px; height: 18px; accent-color: var(--green); margin-top: 2px; }
.text { flex: 1; min-width: 0; }
.text strong { display: block; font-size: 12px; font-weight: 550; }
.text small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; }
.pick select { border: 1px solid #dce3d7; padding: 5px 8px; font-size: 11px; background: #fff; }
.add { display: flex; gap: 8px; padding: 12px 24px 14px; border-top: 1px solid #edf0eb; max-width: 460px; }
.add input { flex: 1; border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
