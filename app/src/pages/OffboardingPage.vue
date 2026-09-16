<script setup lang="ts">
import ChecklistQueue from '@/components/checklists/ChecklistQueue.vue'

/**
 * The offboarding queue (plans 016, 047): every scheduled departure with its
 * checklist. A plan's start_date is the last working day; the employment
 * end date comes from the period. People stay active until they are
 * explicitly marked as former; a departure can be cancelled from the record.
 */
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">HR operations</div>
        <h1>Offboarding, handled properly.</h1>
        <p class="page-sub">
          Departures are scheduled from a person's employment record. People stay active until they
          are explicitly marked as former.
        </p>
      </div>
    </div>
    <ChecklistQueue kind="offboarding" />
  </div>
</template>

<style scoped>
.page-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 24px; }
.page-sub { margin: 0; font-size: 12px; color: var(--muted); max-width: 560px; }
</style>
