<script setup lang="ts">
import { computed } from 'vue'
import { avatarPublicUrl } from '@/lib/avatars'

/**
 * A person's face: their photo when they have one, otherwise initials on the
 * brand gradient (the `.avatar` base style). One component for every place
 * a name appears next to a picture.
 */
const props = withDefaults(defineProps<{ name: string; path?: string | null; size?: 'small' | 'medium' | 'big' }>(), {
  path: null,
  size: 'medium',
})

const url = computed(() => avatarPublicUrl(props.path))
const initials = computed(() =>
  props.name.split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0]?.toUpperCase() ?? '').join(''),
)
</script>

<template>
  <span class="avatar" :class="[size, { photo: url }]" aria-hidden="true">
    <img v-if="url" :src="url" alt="" loading="lazy" decoding="async" />
    <template v-else>{{ initials }}</template>
  </span>
</template>

<style scoped>
.avatar.photo { background: #dfe7dc; overflow: hidden; }
.avatar img { width: 100%; height: 100%; object-fit: cover; display: block; }
.avatar.small { width: 30px; height: 30px; font-size: 10px; }
.avatar.big { width: 76px; height: 76px; font-size: 24px; background: linear-gradient(145deg, #dbe8d2, #b9d3c1); box-shadow: 0 10px 24px -12px rgba(22, 36, 31, 0.5), inset 0 1px 0 rgba(255, 255, 255, 0.8); }
</style>
