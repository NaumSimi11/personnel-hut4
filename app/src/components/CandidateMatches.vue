<script setup lang="ts">
import { todayDb } from '@/lib/compensation'
import {
  NOT_ATTACHABLE,
  contactBadge,
  contactLine,
  contactState,
  matchHistoryLine,
  matchSentence,
  type CandidateMatch,
} from '@/lib/candidatePool'

/**
 * "Is this the same person?" — the hint upsert_sourced_candidate returns
 * before anything is written (plan 052, blueprint §5). Both add dialogs show
 * it in place of their form. Nothing is pre-selected: the person attaches to
 * one match, goes back to the form, or creates a new record anyway; the
 * database never merges by itself. In `job` mode a match can be attached to
 * the job when the RPC would allow it (attachable, not flagged); in `pool`
 * mode there is nothing to attach to. `busy` (the dialog's save in flight)
 * disables every button so a double-click cannot send the choice twice.
 */
withDefaults(defineProps<{ matches: CandidateMatch[]; mode: 'job' | 'pool'; busy?: boolean }>(), { busy: false })
defineEmits<{ attach: [id: string]; createNew: []; back: [] }>()

const today = todayDb()

function badgeClass(m: CandidateMatch): string {
  return contactState(m, today) === 'do_not_contact' ? 'amber' : 'blue'
}

function neverSentence(m: CandidateMatch): string {
  return `${m.full_name} asked not to be contacted again.`
}

function detailLine(m: CandidateMatch): string {
  const work = [m.current_title, m.current_employer].filter(Boolean).join(' @ ')
  return [m.email, m.phone, work].filter(Boolean).join(' · ')
}
</script>

<template>
  <div class="matches" data-testid="candidate-matches">
    <div class="eyebrow">Before saving</div>
    <h2 id="candidate-matches-title">Is this the same person?</h2>
    <ul class="list">
      <li v-for="m in matches" :key="m.id" class="match" :data-testid="`match-${m.id}`">
        <div class="head">
          <b>{{ m.full_name }}</b>
          <span v-if="contactBadge(m, today)" class="badge" :class="badgeClass(m)">{{ contactBadge(m, today) }}</span>
        </div>
        <small v-if="detailLine(m)" class="sub">{{ detailLine(m) }}</small>
        <p>{{ matchSentence(m) }}</p>
        <p class="history">{{ matchHistoryLine(m) }}</p>
        <p v-if="contactLine(m)" class="contact">{{ contactLine(m) }}</p>
        <div class="row-actions">
          <template v-if="mode === 'job'">
            <button
              v-if="m.attachable && !m.do_not_contact"
              class="button small-btn"
              type="button"
              :data-testid="`match-attach-${m.id}`"
              :disabled="busy"
              @click="$emit('attach', m.id)"
            >
              Attach to this job
            </button>
            <span v-else-if="m.do_not_contact" class="muted">{{ neverSentence(m) }}</span>
            <span v-else class="muted">{{ NOT_ATTACHABLE }}</span>
          </template>
          <router-link
            v-if="m.visible"
            class="button secondary small-btn"
            :to="{ name: 'candidate', params: { candidateId: m.id } }"
            target="_blank"
          >
            Open
          </router-link>
        </div>
      </li>
    </ul>
    <div class="actions">
      <button class="button secondary" type="button" data-testid="match-back" :disabled="busy" @click="$emit('back')">Back</button>
      <button class="button secondary" type="button" data-testid="match-create-new" :disabled="busy" @click="$emit('createNew')">
        Create a new candidate anyway
      </button>
    </div>
  </div>
</template>

<style scoped>
h2 { font-size: 19px; margin: 10px 0 14px; }
.list { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; max-height: min(55vh, 460px); overflow: auto; }
.match { border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; font-size: 12px; }
.head { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.sub { display: block; color: var(--muted); font-size: 11px; margin-top: 3px; }
.match p { margin: 6px 0 0; line-height: 1.5; }
.history { color: var(--muted); }
.contact { color: var(--amber); }
.row-actions { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-top: 10px; }
.muted { color: var(--muted); font-size: 11px; }
.small-btn { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 16px; flex-wrap: wrap; }
</style>
