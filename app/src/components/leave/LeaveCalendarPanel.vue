<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { monthGrid, type GridDay } from '@/lib/leave'

/**
 * Who is away, month by month (plan 036). team_leave redacts colleagues'
 * rows to "Away" unless the viewer is the person or holds leave.view /
 * leave.approve — the client never sees more than it should show.
 */

type TeamRow = {
  id: string
  person_id: string
  full_name: string
  start_date: string
  end_date: string
  working_days: number
  status: string
  leave_type_key: string
  note: string | null
  cancellation_asked: boolean
}

const props = defineProps<{ companyId: string; countryCode: string | null }>()

const auth = useAuthStore()
const today = todayDb()
const year = ref(Number(today.slice(0, 4)))
const month = ref(Number(today.slice(5, 7)))
const rows = ref<TeamRow[]>([])
const holidays = ref<Record<string, string>>({})
const closures = ref<Record<string, string>>({})
const loading = ref(true)
const error = ref<string | null>(null)

const grid = computed(() => monthGrid(year.value, month.value))
const monthLabel = computed(() =>
  new Date(Date.UTC(year.value, month.value - 1, 1)).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' }),
)
const fullView = computed(() => auth.can(props.companyId, 'leave.view') || auth.can(props.companyId, 'leave.approve'))

function shift(delta: number): void {
  const d = new Date(Date.UTC(year.value, month.value - 1 + delta, 1))
  year.value = d.getUTCFullYear()
  month.value = d.getUTCMonth() + 1
}

/** Nobody is "on leave" on a day that is not a working day. */
function entriesOn(day: GridDay): TeamRow[] {
  if (day.weekend || holidays.value[day.iso] || closures.value[day.iso]) return []
  return rows.value.filter((r) => r.start_date <= day.iso && r.end_date >= day.iso)
}

function label(r: TeamRow): string {
  const type = r.leave_type_key === 'away' ? 'Away' : r.leave_type_key.replace('_', ' ')
  const state = r.status === 'pending' ? ' (pending)' : r.cancellation_asked ? ' (cancel asked)' : ''
  return `${r.full_name} · ${type}${state}`
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const first = grid.value[0]?.iso ?? today
  const last = grid.value[grid.value.length - 1]?.iso ?? today
  const [teamRes, holRes, cloRes] = await Promise.all([
    supabase.rpc('team_leave', { p_company_id: props.companyId, p_from: first, p_to: last }),
    props.countryCode
      ? supabase.from('public_holidays').select('date, name').eq('country_code', props.countryCode).gte('date', first).lte('date', last)
      : Promise.resolve({ data: [] as { date: string; name: string }[], error: null }),
    supabase.from('company_closures').select('date, name').eq('company_id', props.companyId).gte('date', first).lte('date', last),
  ])
  if (teamRes.error) {
    error.value = teamRes.error.message
    console.error('team_leave failed:', teamRes.error.message)
  } else {
    rows.value = (teamRes.data ?? []) as TeamRow[]
  }
  holidays.value = Object.fromEntries((holRes.data ?? []).map((h) => [h.date, h.name]))
  closures.value = Object.fromEntries((cloRes.data ?? []).map((c) => [c.date, c.name]))
  loading.value = false
}

watch([() => props.companyId, year, month], load)
onMounted(load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>{{ monthLabel }}</h2>
        <p>
          {{ fullView ? 'Leave types and pending requests are shown.' : 'Colleagues show as "Away" — only HR sees the type.' }}
          <span v-if="!countryCode"> No country on this company: statutory holidays are not marked.</span>
        </p>
      </div>
      <div class="nav">
        <button class="button secondary small-btn" type="button" @click="shift(-1)">‹ Previous</button>
        <button class="button secondary small-btn" type="button" @click="shift(1)">Next ›</button>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <div v-else-if="loading" class="empty">Loading calendar…</div>
    <div v-else class="grid" data-testid="leave-calendar">
      <div v-for="d in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']" :key="d" class="dow">{{ d }}</div>
      <div
        v-for="day in grid"
        :key="day.iso"
        class="day"
        :class="{ out: !day.inMonth, weekend: day.weekend, today: day.iso === today, holiday: holidays[day.iso] || closures[day.iso] }"
        :data-date="day.iso"
      >
        <div class="num">{{ day.day }}</div>
        <small v-if="holidays[day.iso]" class="hol">{{ holidays[day.iso] }}</small>
        <small v-if="closures[day.iso]" class="hol">{{ closures[day.iso] }}</small>
        <div v-for="r in entriesOn(day)" :key="r.id" class="entry" :class="{ pending: r.status === 'pending', mine: r.person_id === auth.personId }">
          {{ label(r) }}
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.nav { display: flex; gap: 6px; }
.small-btn { padding: 7px 11px; font-size: 11px; }
.in-card { margin: 14px 24px; }
.grid { display: grid; grid-template-columns: repeat(7, 1fr); border-top: 1px solid #edf0eb; }
.dow { font-size: 9px; text-transform: uppercase; letter-spacing: 0.08em; color: #85907f; padding: 10px 8px; background: #fafbf8; }
.day { min-height: 84px; padding: 6px 8px; border-top: 1px solid #edf0eb; border-left: 1px solid #edf0eb; font-size: 11px; }
.day:nth-child(7n + 1) { border-left: 0; }
.day.out { color: #b5bcb1; background: #fcfcfb; }
.day.weekend { background: #f7f8f5; }
.day.holiday { background: #fbf2df; }
.day.today .num { color: var(--green); font-weight: 700; }
.num { font-size: 11px; font-weight: 550; margin-bottom: 4px; }
.hol { display: block; font-size: 9px; color: #946d24; margin-bottom: 3px; }
.entry { font-size: 10px; padding: 2px 5px; border-radius: 4px; background: #edf5ed; color: #3e744e; margin-bottom: 3px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.entry.pending { background: #f0f1ef; color: #7b8378; border: 1px dashed #c9cfc5; }
.entry.mine { background: #edf2f9; color: #567399; }
@media (max-width: 720px) { .day { min-height: 56px; } .entry { white-space: normal; } }
</style>
