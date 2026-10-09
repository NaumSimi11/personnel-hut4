<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { gapLines, type SetupGaps } from '@/lib/setupGaps'

/**
 * What is missing for the app to work (plan 073): the IT and HR owners and
 * inboxes the viewer's companies still lack, with what breaks without them.
 * For platform admins (every company) and Company HR (their own); nobody
 * else asks. Not dismissible — it goes when the gap does. Admins get a link
 * to each company's Settings, where owners and inboxes are set; HR is told
 * who sets them.
 */
const auth = useAuthStore()
const gaps = ref<SetupGaps | null>(null)

const lines = computed(() => (gaps.value ? gapLines(gaps.value) : []))
const mayAsk = computed(() => auth.isAdmin || auth.canAnywhere('employment.edit'))

onMounted(async () => {
  if (!mayAsk.value) return
  const { data, error } = await supabase.rpc('setup_gaps')
  if (error) {
    console.error('Setup gaps check failed:', error.message)
    return
  }
  gaps.value = data as unknown as SetupGaps
})
</script>

<template>
  <section v-if="lines.length" class="setup-gaps" role="status" aria-label="Missing setup" data-testid="setup-gaps">
    <div v-for="line in lines" :key="line.key" class="line" :class="{ soft: !line.strong }" :data-testid="`setup-gap-${line.key}`">
      <span class="mark" aria-hidden="true">{{ line.strong ? '⚠' : 'ⓘ' }}</span>
      <div class="text">
        <b>{{ line.title }}</b> in
        <template v-for="(c, i) in line.companies" :key="c.id">
          <router-link v-if="gaps?.can_fix" :to="{ name: 'company', params: { companyId: c.id }, query: { tab: 'settings' } }">{{ c.name }}</router-link>
          <span v-else>{{ c.name }}</span><template v-if="c.detail"> ({{ c.detail }})</template><template v-if="i < line.companies.length - 1">, </template>
        </template>.
        <span class="why">{{ line.consequence }}</span>
      </div>
    </div>
    <p class="who">
      {{ gaps?.can_fix ? 'Open a company to set them under Settings.' : 'A platform admin sets these in each company\'s Settings.' }}
    </p>
  </section>
</template>

<style scoped>
.setup-gaps { border: 1px solid #ecd9a8; background: #fdf6e3; border-radius: 12px; padding: 12px 16px; margin: 0 0 18px; }
.line { display: flex; gap: 10px; align-items: baseline; font-size: 12.5px; line-height: 1.6; padding: 3px 0; }
.line.soft { color: #5b6660; }
.mark { flex: none; color: var(--amber); font-size: 13px; }
.line.soft .mark { color: var(--muted); }
.text a { color: inherit; font-weight: 600; }
.why { display: block; color: var(--muted); font-size: 11.5px; }
.who { margin: 6px 0 0 23px; font-size: 11px; color: var(--muted); }
</style>
