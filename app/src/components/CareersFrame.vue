<script setup lang="ts">
import { computed } from 'vue'

/**
 * The public careers frame (plan 019): the company's own branding, no app
 * shell, no sign-in. Everything inside is rendered from the auth service's
 * public endpoints.
 */
export type PublicCompany = {
  name: string
  code: string
  website: string | null
  tagline: string | null
  accentColor: string | null
  logoUrl: string | null
}

const props = defineProps<{ company: PublicCompany | null }>()

const accent = computed(() => props.company?.accentColor ?? '#2f5d4f')

function websiteLabel(url: string): string {
  return url.replace(/^https?:\/\//i, '').replace(/\/$/, '')
}
</script>

<template>
  <div class="careers" :style="{ '--accent': accent }">
    <header class="masthead">
      <div class="masthead-inner">
        <router-link v-if="company" class="brand" :to="{ name: 'careers-company', params: { code: company.code.toLowerCase() } }">
          <span class="mark">
            <img v-if="company.logoUrl" :src="company.logoUrl" alt="" />
            <template v-else>{{ company.code }}</template>
          </span>
          <span class="brand-text">
            <strong>{{ company.name }}</strong>
            <small>Careers</small>
          </span>
        </router-link>
        <a v-if="company?.website" class="site-link" :href="company.website" target="_blank" rel="noopener">
          {{ websiteLabel(company.website) }}
        </a>
      </div>
    </header>
    <main class="content">
      <slot />
    </main>
    <footer class="foot">
      <small v-if="company">{{ company.name }} · Applications are handled by the company's HR team.</small>
    </footer>
  </div>
</template>

<style scoped>
.careers { min-height: 100vh; background: #f6f8f5; color: var(--ink); }
.masthead { background: #fff; border-bottom: 1px solid var(--line); }
.masthead-inner, .content, .foot {
  max-width: 820px;
  margin: 0 auto;
  padding-inline: 20px;
}
.masthead-inner { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding-block: 16px; }
.brand { display: flex; align-items: center; gap: 12px; text-decoration: none; color: inherit; }
.mark {
  display: grid;
  place-items: center;
  width: 44px;
  height: 44px;
  border-radius: 12px;
  background: color-mix(in srgb, var(--accent) 14%, white);
  color: var(--accent);
  font-weight: 700;
  font-size: 13px;
  overflow: hidden;
}
.mark img { width: 100%; height: 100%; object-fit: contain; padding: 15%; box-sizing: border-box; }
.brand-text strong { display: block; font-size: 15px; }
.brand-text small { display: block; font-size: 11px; color: var(--muted); }
.site-link { font-size: 12px; color: var(--accent); text-decoration: none; }
.site-link:hover { text-decoration: underline; }
.content { padding-block: 32px 48px; }
.foot { padding-block: 24px; color: var(--muted); font-size: 11px; }
</style>
