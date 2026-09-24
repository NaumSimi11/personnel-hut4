<script setup lang="ts">
import { computed } from 'vue'
import { upcomingInterviews, whenLabel, type InterviewLite } from '@/lib/hiringBoard'

/**
 * The week's interviews (plan 067), across every company whose candidates
 * the viewer may see — Zoho's "Upcoming Interviews". Each row opens the
 * application, where the interview is run and scored.
 */
const props = defineProps<{ interviews: InterviewLite[]; loading?: boolean }>()

const rows = computed(() => upcomingInterviews(props.interviews))
</script>

<template>
  <div class="card" data-testid="upcoming-interviews">
    <div class="card-head">
      <div>
        <h2>Upcoming interviews</h2>
        <p>Scheduled in the next seven days.</p>
      </div>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <div v-else-if="!rows.length" class="empty">No interviews in the next seven days.</div>
    <ul v-else class="list">
      <li v-for="r in rows" :key="r.id">
        <component
          :is="r.applicationId ? 'router-link' : 'div'"
          class="row"
          :to="r.applicationId ? { name: 'application', params: { applicationId: r.applicationId } } : undefined"
        >
          <span class="row-text">
            <b>{{ r.candidate }}</b>
            <small>{{ r.job }} · {{ r.company }} · {{ r.kind }}</small>
            <small v-if="r.panel.length" class="panel">With {{ r.panel.join(', ') }}</small>
          </span>
          <span class="row-side">{{ whenLabel(r.scheduledAt) }}</span>
        </component>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.card { margin: 0; }
.list { list-style: none; margin: 0; padding: 0; }
.row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 24px; border-top: 1px solid var(--line); color: var(--ink); text-decoration: none; }
a.row:hover { background: #f7f9f5; }
.row-text { display: grid; gap: 2px; min-width: 0; }
.row-text b { font-size: 13px; font-weight: 600; }
.row-text small { font-size: 11px; color: var(--muted); }
.row-side { font-size: 12px; font-weight: 600; color: var(--green-deep); white-space: nowrap; }
</style>
