<script setup lang="ts">
import { computed } from 'vue'
import { DEFAULT_ACCENT, type CompanyBrand } from '@/lib/companyForm'
import { logoPublicUrl } from '@/lib/companyLogo'

/**
 * A company's visual mark: its logo when one is uploaded, otherwise the
 * short code on a tint of its accent colour. The colour is validated as hex
 * by the database (0011), so it is safe to drop into a style binding.
 */
const props = withDefaults(
  defineProps<{ shortCode: string; brand: CompanyBrand; size?: 'small' | 'large' }>(),
  { size: 'small' },
)

const accent = computed(() => props.brand.accent_color ?? DEFAULT_ACCENT)
const logoUrl = computed(() => (props.brand.logo_path ? logoPublicUrl(props.brand.logo_path) : null))
const long = computed(() => props.shortCode.length > 3)
</script>

<template>
  <span class="company-tile" :class="[size, { long }]" :style="{ '--accent': accent }" aria-hidden="true">
    <img v-if="logoUrl" class="logo" :src="logoUrl" alt="" />
    <template v-else>{{ shortCode }}</template>
  </span>
</template>

<style scoped>
.company-tile {
  --accent: #2f5d4f;
  display: grid;
  place-items: center;
  flex-shrink: 0;
  background: color-mix(in srgb, var(--accent) 14%, white);
  color: var(--accent);
  font-weight: 650;
  overflow: hidden;
}
.company-tile.small { width: 42px; height: 42px; border-radius: 11px; font-size: 15px; }
.company-tile.large { width: 58px; height: 58px; border-radius: 14px; font-size: 20px; }
.company-tile.small.long { font-size: 12px; letter-spacing: -0.01em; }
.company-tile.large.long { font-size: 16px; letter-spacing: -0.01em; }
.logo { width: 100%; height: 100%; object-fit: contain; padding: 15%; box-sizing: border-box; }
</style>
