<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { inDaysLabel, shoutoutLine, type DashboardSnapshot } from '@/lib/dashboard'
import { shortDate } from '@/lib/leave'

/**
 * The prototype's "Celebrate" block (plan 044): give kudos and read the
 * wall, birthdays and work anniversaries in the next 30 days, new
 * teammates, and a fun corner. The team cards need people.view (birthdays
 * need personal.view, applied in the database, which is why they can be
 * empty while the others are not; the year never leaves the database).
 * Kudos stay for everyone: you thank people you may see, and you always
 * read what you gave or received.
 */
const props = defineProps<{ snapshot: DashboardSnapshot; showTeam: boolean; loading?: boolean }>()
const emit = defineEmits<{ changed: [] }>()

const auth = useAuthStore()
const MESSAGE_MAX = 280

const toId = ref('')
const message = ref('')
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const shoutoutId = ref<string | null>(null)

const shoutout = computed(() => props.snapshot.colleagues.find((c) => c.id === shoutoutId.value) ?? null)
const canPost = computed(() => !!auth.personId && !!toId.value && message.value.trim().length > 0 && message.value.length <= MESSAGE_MAX)

async function postKudos(): Promise<void> {
  error.value = null
  notice.value = null
  if (!canPost.value || !auth.personId) return
  busy.value = true
  const { error: err } = await supabase
    .from('kudos')
    .insert({ from_person_id: auth.personId, to_person_id: toId.value, message: message.value.trim() })
  busy.value = false
  if (err) {
    error.value = err.message.includes('row-level security') ? 'You can only thank colleagues whose records you may see.' : 'Could not post the kudos. Try again.'
    console.error('Kudos insert failed:', err.message)
    return
  }
  const name = props.snapshot.colleagues.find((c) => c.id === toId.value)?.full_name ?? 'your colleague'
  notice.value = `Kudos to ${name} is on the wall.`
  message.value = ''
  toId.value = ''
  emit('changed')
}

async function removeKudos(id: string): Promise<void> {
  error.value = null
  const { error: err } = await supabase.from('kudos').delete().eq('id', id)
  if (err) {
    error.value = 'Could not remove the kudos.'
    console.error('Kudos delete failed:', err.message)
    return
  }
  emit('changed')
}

function surprise(): void {
  const pool = props.snapshot.colleagues.filter((c) => c.id !== shoutoutId.value)
  if (!pool.length) return
  shoutoutId.value = pool[Math.floor(Math.random() * pool.length)]!.id
}

function when(iso: string): string {
  return shortDate(iso.slice(0, 10))
}
</script>

<template>
  <section class="celebrate" aria-labelledby="celebrate-heading" data-testid="celebrate">
    <div class="section-label">
      <span id="celebrate-heading">Celebrate</span>
      <small>{{ showTeam ? 'Kudos, birthdays, anniversaries and new faces on your team.' : 'The thanks you gave and received.' }}</small>
    </div>
    <div class="grid">
      <div class="col">
        <div class="card">
          <div class="card-head">
            <div>
              <h2>Give kudos</h2>
              <p>Say what a colleague did well. It goes on the wall for the team.</p>
            </div>
          </div>
          <form class="card-body" novalidate data-testid="kudos-form" @submit.prevent="postKudos">
            <div class="field">
              <label for="kudos-to">To</label>
              <select id="kudos-to" v-model="toId" :disabled="loading || !snapshot.colleagues.length">
                <option value="">— Select a colleague —</option>
                <option v-for="c in snapshot.colleagues" :key="c.id" :value="c.id">{{ c.full_name }} · {{ c.company_name }}</option>
              </select>
              <small v-if="!loading && !snapshot.colleagues.length" class="hint left">You can thank colleagues whose records you may see.</small>
            </div>
            <div class="field">
              <label for="kudos-message">Message</label>
              <input id="kudos-message" v-model="message" :maxlength="MESSAGE_MAX" placeholder="What did they do well?" autocomplete="off" />
              <small class="hint">{{ message.length }}/{{ MESSAGE_MAX }}</small>
            </div>
            <p v-if="error" class="error-note" role="alert">{{ error }}</p>
            <p v-if="notice" class="notice" role="status">{{ notice }}</p>
            <button class="button" type="submit" :disabled="busy || !canPost">{{ busy ? 'Posting…' : 'Post kudos' }}</button>
          </form>
        </div>

        <div class="card">
          <div class="card-head">
            <div>
              <h2>Kudos wall</h2>
              <p>{{ showTeam ? 'The latest thanks across your team.' : 'What you gave, and what colleagues sent you.' }}</p>
            </div>
          </div>
          <div v-if="loading" class="empty">Loading…</div>
          <div v-else-if="!snapshot.kudos.length" class="empty">No kudos yet — be the first to recognise a teammate.</div>
          <ul v-else class="list wall" data-testid="kudos-wall">
            <li v-for="k in snapshot.kudos" :key="k.id" class="kudos">
              <div class="kudos-head">
                <span><b>{{ k.from_name }}</b> → <b>{{ k.to_name }}</b></span>
                <small>{{ when(k.created_at) }}</small>
              </div>
              <p class="kudos-msg">{{ k.message }}</p>
              <button v-if="k.mine || auth.isAdmin" class="linkish" type="button" @click="removeKudos(k.id)">Remove</button>
            </li>
          </ul>
        </div>
      </div>

      <div v-if="showTeam" class="col">
        <div class="card">
          <div class="card-head"><div><h2>Birthdays</h2><p>Next 30 days.</p></div></div>
          <div v-if="loading" class="empty">Loading…</div>
          <div v-else-if="!snapshot.birthdays.length" class="empty">No birthdays in the next 30 days.</div>
          <ul v-else class="list">
            <li v-for="b in snapshot.birthdays" :key="b.id" class="row">
              <span class="row-text"><b>{{ b.full_name }}</b><small>{{ b.job_title ?? b.company_name }} · {{ b.on_day }}</small></span>
              <span class="row-side" :class="{ today: b.in_days === 0 }">{{ b.in_days === 0 ? '🎉 Today' : inDaysLabel(b.in_days) }}</span>
            </li>
          </ul>
        </div>
        <div class="card">
          <div class="card-head"><div><h2>Work anniversaries</h2><p>Next 30 days.</p></div></div>
          <div v-if="loading" class="empty">Loading…</div>
          <div v-else-if="!snapshot.anniversaries.length" class="empty">No work anniversaries in the next 30 days.</div>
          <ul v-else class="list">
            <li v-for="a in snapshot.anniversaries" :key="a.id" class="row">
              <span class="row-text"><b>{{ a.full_name }}</b><small>{{ a.years }} year{{ a.years === 1 ? '' : 's' }} · {{ a.job_title ?? a.company_name }}</small></span>
              <span class="row-side" :class="{ today: a.in_days === 0 }">{{ inDaysLabel(a.in_days) }}</span>
            </li>
          </ul>
        </div>
        <div class="card">
          <div class="card-head"><div><h2>New teammates</h2><p>Started in the last 30 days.</p></div></div>
          <div v-if="loading" class="empty">Loading…</div>
          <div v-else-if="!snapshot.newcomers.length" class="empty">No new hires in the last 30 days.</div>
          <ul v-else class="list">
            <li v-for="n in snapshot.newcomers" :key="n.id" class="row">
              <span class="row-text"><b>{{ n.full_name }}</b><small>{{ n.job_title ?? '—' }} · {{ n.company_name }}</small></span>
              <span class="row-side">Started {{ shortDate(n.start_date) }}</span>
            </li>
          </ul>
        </div>
      </div>

      <div class="col">
        <slot name="aside" />
        <div v-if="showTeam" class="card fun">
          <div class="card-head"><div><h2>Fun corner</h2><p>Real numbers, presented lightly.</p></div></div>
          <div class="card-body facts">
            <p class="fact">🙌 <b>{{ snapshot.top_kudos?.full_name ?? '—' }}</b> {{ snapshot.top_kudos ? `has the most kudos (${snapshot.top_kudos.count})` : 'No kudos yet — be the first!' }}</p>
            <p class="fact">🚀 <b>{{ snapshot.biggest_team?.name ?? '—' }}</b> {{ snapshot.biggest_team ? `is the biggest team (${snapshot.biggest_team.people} people)` : '' }}</p>
            <p class="fact">🎈 <b>{{ snapshot.anniversaries_this_year }}</b> teammate{{ snapshot.anniversaries_this_year === 1 ? '' : 's' }} celebrating a work anniversary this year</p>
            <div class="shoutout">
              <div v-if="shoutout" class="shoutout-card" data-testid="shoutout">
                <b>📣 {{ shoutout.full_name }}</b>
                <span>{{ shoutout.full_name.split(' ')[0] }} {{ shoutoutLine(shoutout.id) }}</span>
              </div>
              <p v-else class="muted">Spin for a random teammate shoutout.</p>
              <button class="button secondary small-btn" type="button" :disabled="!snapshot.colleagues.length" @click="surprise">🎲 Surprise me</button>
            </div>
          </div>
        </div>
      </div>
    </div>
  </section>
</template>

<style scoped>
.celebrate { margin-bottom: 22px; }
.section-label { display: flex; align-items: baseline; gap: 10px; margin: 0 0 12px; font-size: 13px; font-weight: 650; letter-spacing: 0.01em; }
.section-label small { font-size: 12px; font-weight: 400; color: var(--muted); }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 14px; align-items: start; }
@media (max-width: 700px) { .grid { grid-template-columns: 1fr; } }
.col { display: grid; gap: 14px; }
.card { margin: 0; }
.hint { display: block; margin-top: 4px; font-size: 11px; color: var(--muted); text-align: right; }
.hint.left { text-align: left; }
.notice { padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin: 0 0 12px; }
.list { list-style: none; margin: 0; padding: 0; }
.row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 24px; border-top: 1px solid var(--line); }
.row-text { display: grid; gap: 2px; min-width: 0; }
.row-text b { font-size: 13px; font-weight: 600; }
.row-text small { font-size: 11px; color: var(--muted); }
.row-side { font-size: 12px; color: var(--muted); white-space: nowrap; }
.row-side.today { color: var(--green); font-weight: 650; }
.wall .kudos { padding: 12px 24px; border-top: 1px solid var(--line); display: grid; gap: 4px; }
.kudos-head { display: flex; justify-content: space-between; gap: 10px; font-size: 12px; }
.kudos-head small { color: var(--muted); }
.kudos-msg { margin: 0; font-size: 13px; }
.linkish { background: none; border: 0; padding: 0; color: var(--muted); font-size: 11px; text-decoration: underline; cursor: pointer; justify-self: start; min-height: 24px; }
.linkish:hover { color: var(--red); }
.fun { border-color: #dfe9dd; background: linear-gradient(160deg, #fff, var(--green-soft)); }
.facts { display: grid; gap: 10px; }
.fact { margin: 0; font-size: 13px; }
.shoutout { margin-top: 6px; display: grid; gap: 10px; }
.shoutout-card { display: grid; gap: 4px; padding: 12px 14px; border-radius: var(--radius-sm); background: var(--surface); border: 1px solid var(--line); font-size: 13px; }
.shoutout-card span { color: var(--muted); font-size: 12px; }
.muted { margin: 0; font-size: 12px; color: var(--muted); }
.small-btn { font-size: 11px; padding: 7px 11px; justify-self: start; }
</style>
