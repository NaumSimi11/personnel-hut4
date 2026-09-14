<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { dayKind, leaveProgress, monthGrid, type GridDay } from '@/lib/leave'

/**
 * Who is away, month by month (plan 036). team_leave redacts colleagues'
 * rows to "Away" unless the viewer is the person or holds leave.view /
 * leave.approve — the client never sees more than it should show.
 */

type Company = { id: string; name: string; country_code: string | null }
type TeamRow = {
  company_id: string
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

const props = defineProps<{ companies: Company[] }>()

const auth = useAuthStore()
const today = todayDb()
const year = ref(Number(today.slice(0, 4)))
const month = ref(Number(today.slice(5, 7)))
const rows = ref<TeamRow[]>([])
const holidays = ref<Record<string, string>>({})
const closures = ref<Record<string, string>>({})
const loading = ref(true)
const error = ref<string | null>(null)
const selected = ref<string | null>(null)

// The day rail: what the clicked day is and who is away on it. A person's
// name links to their record only when the viewer may open it (their own,
// or leave.view / leave.approve in that company — the same rule the
// database applied when it decided whether to redact the row).
const selectedKind = computed(() => (selected.value ? dayKind(selected.value, holidays.value, closures.value) : 'working'))
const selectedLeaves = computed(() => (selected.value ? entriesOn({ iso: selected.value, day: 0, inMonth: true, weekend: selectedKind.value === 'weekend' }) : []))
const kindText: Record<string, { title: string; sub: string }> = {
  working: { title: 'Working day', sub: 'A normal day' },
  weekend: { title: 'Weekend', sub: 'Not a working day' },
  holiday: { title: 'Public holiday', sub: 'Does not count as leave' },
  closure: { title: 'Company closure', sub: 'Does not count as leave' },
}
function dayTitle(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' })
}
function typeLabel(r: TeamRow): string {
  return r.leave_type_key === 'away' ? 'Away' : r.leave_type_key.replace('_', ' ')
}
function canOpen(r: TeamRow): boolean {
  return r.person_id === auth.personId || r.leave_type_key !== 'away'
}
function progressText(r: TeamRow): string {
  const p = leaveProgress(r, selected.value ?? r.start_date)
  return p.of === 1 ? 'one day' : `day ${p.day} of ${p.of}`
}
function select(day: GridDay): void {
  selected.value = selected.value === day.iso ? null : day.iso
}

const grid = computed(() => monthGrid(year.value, month.value))
const monthLabel = computed(() =>
  new Date(Date.UTC(year.value, month.value - 1, 1)).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' }),
)
const fullView = computed(() => props.companies.every((c) => auth.can(c.id, 'leave.view') || auth.can(c.id, 'leave.approve')))
const countries = computed(() => Array.from(new Set(props.companies.map((c) => c.country_code).filter((c): c is string => !!c))))
const many = computed(() => props.companies.length > 1)
const nameOf = (id: string) => props.companies.find((c) => c.id === id)?.name ?? ''

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
  const where = many.value ? ` · ${nameOf(r.company_id)}` : ''
  return `${r.full_name} · ${type}${state}${where}`
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const first = grid.value[0]?.iso ?? today
  const last = grid.value[grid.value.length - 1]?.iso ?? today
  // One team_leave call per company (the redaction is per company), merged.
  const [teamRes, holRes, cloRes] = await Promise.all([
    Promise.all(props.companies.map((c) => supabase.rpc('team_leave', { p_company_id: c.id, p_from: first, p_to: last }).then((r) => ({ ...r, company: c })))),
    countries.value.length
      ? supabase.from('public_holidays').select('date, name, country_code').in('country_code', countries.value).gte('date', first).lte('date', last)
      : Promise.resolve({ data: [] as { date: string; name: string; country_code: string }[], error: null }),
    supabase.from('company_closures').select('date, name, company_id').in('company_id', props.companies.map((c) => c.id)).gte('date', first).lte('date', last),
  ])
  const failed = teamRes.find((r) => r.error)
  if (failed?.error) {
    error.value = failed.error.message
    console.error('team_leave failed:', failed.error.message)
  } else {
    rows.value = teamRes.flatMap((r) => ((r.data ?? []) as Omit<TeamRow, 'company_id'>[]).map((row) => ({ ...row, company_id: r.company.id })))
  }
  // With several countries or companies, the label says which one the day off belongs to.
  const label = (name: string, tag: string, tagged: boolean) => (tagged ? `${name} (${tag})` : name)
  holidays.value = Object.fromEntries(
    (holRes.data ?? []).map((h) => [h.date, label(h.name, h.country_code, countries.value.length > 1)]),
  )
  closures.value = Object.fromEntries((cloRes.data ?? []).map((c) => [c.date, label(c.name, nameOf(c.company_id), many.value)]))
  loading.value = false
}

watch([() => props.companies, year, month], load)
onMounted(load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>{{ monthLabel }}</h2>
        <p>
          {{ fullView ? 'Leave types and pending requests are shown.' : 'Colleagues show as "Away" — only HR sees the type.' }}
          <span v-if="!countries.length"> No country on this company: statutory holidays are not marked.</span>
        </p>
      </div>
      <div class="nav">
        <button class="button secondary small-btn" type="button" @click="shift(-1)">‹ Previous</button>
        <button class="button secondary small-btn" type="button" @click="shift(1)">Next ›</button>
      </div>
    </div>
    <p v-if="error" class="error-note in-card" role="alert">{{ error }}</p>
    <div v-else-if="loading" class="empty">Loading calendar…</div>
    <div v-else class="layout" :class="{ open: selected }">
    <div class="grid" data-testid="leave-calendar">
      <div v-for="d in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']" :key="d" class="dow">{{ d }}</div>
      <div
        v-for="day in grid"
        :key="day.iso"
        class="day"
        :class="{ out: !day.inMonth, weekend: day.weekend, today: day.iso === today, holiday: holidays[day.iso] || closures[day.iso], selected: day.iso === selected }"
        :data-date="day.iso"
        role="button"
        tabindex="0"
        :aria-pressed="day.iso === selected"
        @click="select(day)"
        @keydown.enter.prevent="select(day)"
        @keydown.space.prevent="select(day)"
      >
        <div class="num">{{ day.day }}</div>
        <small v-if="holidays[day.iso]" class="hol">{{ holidays[day.iso] }}</small>
        <small v-if="closures[day.iso]" class="hol">{{ closures[day.iso] }}</small>
        <div v-for="r in entriesOn(day)" :key="r.id" class="entry" :class="{ pending: r.status === 'pending', mine: r.person_id === auth.personId }">
          {{ label(r) }}
        </div>
      </div>
    </div>
    <aside v-if="selected" class="rail" data-testid="day-rail" :aria-label="dayTitle(selected)">
      <div class="rail-head">
        <div>
          <div class="eyebrow">{{ dayTitle(selected) }}</div>
          <strong>{{ kindText[selectedKind].title }}</strong>
          <small>{{ holidays[selected] || closures[selected] || kindText[selectedKind].sub }}</small>
        </div>
        <button class="button secondary small-btn" type="button" aria-label="Close day" @click="selected = null"><svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8" /></svg></button>
      </div>
      <div class="rail-count">
        <template v-if="selectedLeaves.length">
          <b>{{ selectedLeaves.length }}</b> {{ selectedLeaves.length === 1 ? 'person is' : 'people are' }} away
        </template>
        <template v-else-if="selectedKind !== 'working'">Nobody is away — not a working day.</template>
        <template v-else>Nobody is away — a full team.</template>
      </div>
      <ul class="rail-people">
        <li v-for="r in selectedLeaves" :key="r.id">
          <router-link v-if="canOpen(r)" :to="{ name: 'person', params: { personId: r.person_id } }"><b>{{ r.full_name }}</b></router-link>
          <b v-else>{{ r.full_name }}</b>
          <small>
            {{ typeLabel(r) }}{{ r.status === 'pending' ? ' · pending' : '' }}{{ r.cancellation_asked ? ' · asks to cancel' : '' }}{{ many ? ` · ${nameOf(r.company_id)}` : '' }}
          </small>
          <small>{{ r.start_date }} → {{ r.end_date }} · {{ progressText(r) }}</small>
          <small v-if="r.note" class="note">“{{ r.note }}”</small>
        </li>
      </ul>
    </aside>
    </div>
  </div>
</template>

<style scoped>
.nav { display: flex; gap: 6px; }
.small-btn { padding: 7px 11px; font-size: 11px; }
.in-card { margin: 14px 24px; }
.layout { display: grid; grid-template-columns: 1fr; }
.layout.open { grid-template-columns: minmax(0, 1fr) 280px; }
.grid { display: grid; grid-template-columns: repeat(7, 1fr); border-top: 1px solid #edf0eb; }
.day { cursor: pointer; }
.day:hover { box-shadow: inset 0 0 0 1px #c9d3c4; }
.day.selected { box-shadow: inset 0 0 0 2px var(--green); }
.rail { border-top: 1px solid #edf0eb; border-left: 1px solid #edf0eb; padding: 16px 18px; font-size: 12px; }
.rail-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 8px; }
.rail-head strong { display: block; font-size: 15px; margin-top: 4px; }
.rail-head small { display: block; color: var(--muted); font-size: 11px; }
.rail-count { margin: 14px 0 10px; font-size: 12px; }
.rail-people { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
.rail-people li { border: 1px solid var(--line); border-radius: 8px; padding: 9px 11px; display: grid; gap: 2px; }
.rail-people small { color: var(--muted); font-size: 11px; }
.rail-people .note { color: var(--ink); }
@media (max-width: 720px) { .layout.open { grid-template-columns: 1fr; } .rail { border-left: 0; } }
.dow { font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: #85907f; padding: 10px 8px; background: #fafbf8; }
.day { min-height: 84px; padding: 6px 8px; border-top: 1px solid #edf0eb; border-left: 1px solid #edf0eb; font-size: 11px; }
.day:nth-child(7n + 1) { border-left: 0; }
.day.out { color: #b5bcb1; background: #fcfcfb; }
.day.weekend { background: #f7f8f5; }
.day.holiday { background: #fbf2df; }
.day.today .num { color: var(--green); font-weight: 700; }
.num { font-size: 11px; font-weight: 550; margin-bottom: 4px; }
.hol { display: block; font-size: 11px; color: #946d24; margin-bottom: 3px; }
.entry { font-size: 11px; padding: 2px 5px; border-radius: 4px; background: #edf5ed; color: #3e744e; margin-bottom: 3px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.entry.pending { background: #f0f1ef; color: #7b8378; border: 1px dashed #c9cfc5; }
.entry.mine { background: #edf2f9; color: #567399; }
@media (max-width: 720px) { .day { min-height: 56px; } .entry { white-space: normal; } }
</style>
