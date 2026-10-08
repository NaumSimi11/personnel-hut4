<script setup lang="ts">
import { computed, ref } from 'vue'
import { assetLabel, assetSuggestions, kitPickerHint, type KitAssetOption } from '@/lib/kitAssets'

/**
 * One free asset for one starter-kit line (plan 072). Focus shows the free
 * stock of the line's kind first; typing narrows by tag, model, serial, type
 * or owner; arrows and Enter pick, Escape closes. The pick shows as a chip
 * that × clears. Nothing picked is fine — the line can be ticked without one.
 */
const props = defineProps<{ options: KitAssetOption[]; item: string; modelValue: string }>()
const emit = defineEmits<{ 'update:modelValue': [id: string] }>()

const uid = `asset-${Math.random().toString(36).slice(2, 9)}`
const query = ref('')
const active = ref(0)
const focused = ref(false)

const chosen = computed(() => props.options.find((o) => o.id === props.modelValue) ?? null)
const suggestions = computed(() => assetSuggestions(props.options, props.item, query.value))
const hint = computed(() => kitPickerHint(props.item, props.options))

function pick(o: KitAssetOption): void {
  emit('update:modelValue', o.id)
  query.value = ''
  active.value = 0
  focused.value = false
}

function onKeydown(e: KeyboardEvent): void {
  const n = suggestions.value.length
  if (e.key === 'ArrowDown' && n) {
    e.preventDefault()
    active.value = (active.value + 1) % n
  } else if (e.key === 'ArrowUp' && n) {
    e.preventDefault()
    active.value = (active.value - 1 + n) % n
  } else if (e.key === 'Enter') {
    e.preventDefault()
    const o = suggestions.value[active.value]
    if (o) pick(o)
  } else if (e.key === 'Escape') {
    query.value = ''
    focused.value = false
  }
}
</script>

<template>
  <div class="asset-picker">
    <div v-if="chosen" class="chosen" :data-testid="`kit-asset-chosen-${item}`">
      <span>{{ assetLabel(chosen) }}</span>
      <button type="button" class="clear" :aria-label="`Clear the asset for ${item}`" @click="emit('update:modelValue', '')">×</button>
    </div>
    <div v-else class="box">
      <input
        v-model="query"
        type="text"
        role="combobox"
        autocomplete="off"
        :aria-expanded="focused"
        :aria-controls="`${uid}-list`"
        :aria-activedescendant="focused && suggestions.length ? `${uid}-opt-${active}` : undefined"
        :aria-label="`Asset for ${item}`"
        placeholder="Pick a free asset (optional)"
        :data-testid="`kit-asset-search-${item}`"
        @input="active = 0"
        @keydown="onKeydown"
        @focus="focused = true"
        @blur="focused = false"
      />
      <ul v-if="focused" :id="`${uid}-list`" class="suggestions" role="listbox">
        <li
          v-for="(o, i) in suggestions"
          :id="`${uid}-opt-${i}`"
          :key="o.id"
          role="option"
          :aria-selected="i === active"
          class="option"
          :class="{ active: i === active }"
          @mousedown.prevent="pick(o)"
          @mouseenter="active = i"
        >
          {{ assetLabel(o) }}
        </li>
        <li v-if="!suggestions.length" class="none">{{ query.trim() ? `Nothing free matches “${query.trim()}”.` : 'No free equipment.' }}</li>
      </ul>
    </div>
    <small class="hint">{{ hint }}</small>
  </div>
</template>

<style scoped>
.asset-picker { max-width: 460px; }
.box { position: relative; }
.box input { width: 100%; border: 1px solid #dce3d7; padding: 6px 9px; font-size: 11px; background: #fff; color: var(--ink); border-radius: 6px; }
.chosen { display: inline-flex; align-items: center; gap: 4px; max-width: 100%; font-size: 11px; font-weight: 550; color: var(--green); background: var(--green-soft); border: 1px solid var(--green); border-radius: 999px; padding: 3px 5px 3px 10px; }
.chosen span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.clear { background: none; border: 0; padding: 0 5px; font-size: 14px; line-height: 1; color: inherit; cursor: pointer; }
.suggestions { position: absolute; z-index: 5; left: 0; right: 0; top: calc(100% + 4px); list-style: none; margin: 0; padding: 4px; background: #fff; border: 1px solid var(--line); border-radius: 9px; box-shadow: 0 12px 30px #122f3024; max-height: 260px; overflow-y: auto; }
.option { padding: 7px 9px; font-size: 11px; border-radius: 6px; cursor: pointer; }
.option.active { background: var(--green-soft); color: var(--green); }
.none { padding: 7px 9px; font-size: 11px; color: var(--muted); }
.hint { display: block; margin-top: 4px; font-size: 10.5px; color: var(--muted); }
</style>
