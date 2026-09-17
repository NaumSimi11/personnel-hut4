<script setup lang="ts">
import { ref } from 'vue'

/**
 * A card that opens only when someone asks for it.
 *
 * My workspace shows everything the app knows about you — tasks, profile,
 * employment, leave, compensation, documents, equipment, access, projects — and
 * for someone holding every role that is four screens of scrolling to reach the
 * last of it. Almost all of it is reference: true, occasionally needed, and in
 * the way the rest of the time.
 *
 * So the sections start closed, and the header carries enough to decide without
 * opening: a count where there is one to give, and a line of summary. A closed
 * section that tells you nothing just moves the scrolling into clicking.
 */
withDefaults(
  defineProps<{
    title: string
    /** How many things are inside, when that is a useful thing to know. */
    count?: number | null
    /** A few words about what is in there, read before opening. */
    hint?: string | null
    /** Opens on first render — for the one or two sections worth seeing at once. */
    openByDefault?: boolean
  }>(),
  { count: null, hint: null, openByDefault: false },
)

const open = ref(false)
</script>

<template>
  <section class="card collapsible" :class="{ open }">
    <h2 class="heading">
      <button class="head" type="button" :aria-expanded="open" @click="open = !open">
        <span class="chevron" :class="{ open }" aria-hidden="true">›</span>
        <span class="titles">
          <span class="title">{{ title }}</span>
          <small v-if="hint">{{ hint }}</small>
        </span>
        <span v-if="count !== null" class="count">{{ count }}</span>
      </button>
    </h2>
    <div v-if="open" class="body">
      <slot />
    </div>
  </section>
</template>

<style scoped>
.collapsible { margin-bottom: 14px; overflow: hidden; }
/* The disclosure pattern: a button inside the heading, so the page still has
   a heading structure to navigate by. */
.heading { margin: 0; font-size: inherit; font-weight: inherit; }
.head {
  display: flex; align-items: center; gap: 12px; width: 100%;
  padding: 15px 24px; background: none; border: 0; cursor: pointer;
  text-align: left; color: var(--ink); font: inherit;
}
.head:hover { background: #f7f9f5; }
.collapsible.open .head { border-bottom: 1px solid #edf0eb; }
.titles { flex: 1; display: grid; gap: 2px; }
.title { font-size: 13px; font-weight: 600; }
.titles small { font-size: 11px; color: var(--muted); }
.count {
  min-width: 22px; padding: 2px 8px; border-radius: 999px;
  background: #eef2ea; color: var(--ink); font-size: 11px; font-weight: 600; text-align: center;
}
.chevron { font-size: 15px; color: var(--muted); transition: transform 0.15s ease; }
.chevron.open { transform: rotate(90deg); }
@media (prefers-reduced-motion: reduce) { .chevron { transition: none; } }
.body { padding: 0; }
</style>
