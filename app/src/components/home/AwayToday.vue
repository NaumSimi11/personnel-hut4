<script setup lang="ts">
import type { AwayRow } from '@/lib/dashboard'
import { shortDate } from '@/lib/leave'

/** Who is on approved leave today, among the leave the viewer may see (plan 044). */
defineProps<{ rows: AwayRow[]; loading?: boolean }>()
</script>

<template>
  <div class="card" data-testid="away-today">
    <div class="card-head">
      <div>
        <h2>Away today</h2>
        <p>Approved leave covering today.</p>
      </div>
      <router-link class="button secondary small-btn" :to="{ name: 'leave' }">Calendar</router-link>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <div v-else-if="!rows.length" class="empty">Everyone you can see is in today.</div>
    <ul v-else class="list">
      <li v-for="r in rows" :key="r.id" class="row">
        <span class="row-text"><b>{{ r.name }}</b><small>{{ r.type }}</small></span>
        <span class="row-side">{{ r.backOn ? 'Back tomorrow' : `Until ${shortDate(r.until)}` }}</span>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.card { margin: 0; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.list { list-style: none; margin: 0; padding: 0; }
.row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 24px; border-top: 1px solid var(--line); }
.row-text { display: grid; gap: 2px; min-width: 0; }
.row-text b { font-size: 13px; font-weight: 600; }
.row-text small { font-size: 11px; color: var(--muted); text-transform: capitalize; }
.row-side { font-size: 12px; color: var(--muted); white-space: nowrap; }
</style>
