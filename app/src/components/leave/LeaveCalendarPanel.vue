<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { LEAVE_TYPE_TONE, dayKind, leaveProgress, monthGrid, shortName, type GridDay } from '@/lib/leave'

/**
 * Who is away, month by month (plan 036, styled per 039's day rail and
 * Field Notebook's coverage view). team_leave redacts colleagues' rows to
 * "Away" unless the viewer is the person or holds leave.view /
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

const MAX_CHIPS = 4

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

const grid = computed(() => monthGrid(year.value, month.value))
const monthKey = computed(() => `${year.value}-${String(month.value).padStart(2, '0')}`)
const monthLabel = computed(() =>
  new Date(Date.UTC(year.value, month.value - 1, 1)).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' }),
)
const isCurrentMonth = computed(() => today.startsWith(monthKey.value))
const fullView = computed(() => props.companies.every((c) => auth.can(c.id, 'leave.view') || auth.can(c.id, 'leave.approve')))
const countries = computed(() => Array.from(new Set(props.companies.map((c) => c.country_code).filter((c): c is string => !!c))))
const many = computed(() => props.companies.length > 1)
const nameOf = (id: string) => props.companies.find((c) => c.id === id)?.name ?? ''

// ---------------------------------------------------------------- stats
// The numbers at the top: what an HR person checks first when the page opens.
const inMonth = (r: TeamRow) => r.start_date <= `${monthKey.value}-31` && r.end_date >= `${monthKey.value}-01`
const stats = computed(() => {
  const awayToday = rows.value.filter((r) => r.status === 'approved' && r.start_date <= today && r.end_date >= today)
  const pending = rows.value.filter((r) => r.status === 'pending')
  const monthRows = rows.value.filter((r) => r.status === 'approved' && inMonth(r))
  const monthHolidays = Object.keys(holidays.value).filter((d) => d.startsWith(monthKey.value)).length
  return {
    awayToday: new Set(awayToday.map((r) => r.person_id)).size,
    pending: pending.length,
    peopleThisMonth: new Set(monthRows.map((r) => r.person_id)).size,
    daysThisMonth: monthRows.reduce((sum, r) => sum + Number(r.working_days), 0),
    holidays: monthHolidays,
  }
})

// ------------------------------------------------------------- the grid
function shift(delta: number): void {
  const d = new Date(Date.UTC(year.value, month.value - 1 + delta, 1))
  year.value = d.getUTCFullYear()
  month.value = d.getUTCMonth() + 1
}
function goToday(): void {
  year.value = Number(today.slice(0, 4))
  month.value = Number(today.slice(5, 7))
  selected.value = today
}

/** Nobody is "on leave" on a day that is not a working day. */
function entriesOn(day: GridDay): TeamRow[] {
  if (day.weekend || holidays.value[day.iso] || closures.value[day.iso]) return []
  return rows.value.filter((r) => r.start_date <= day.iso && r.end_date >= day.iso)
}
function visibleChips(day: GridDay): TeamRow[] {
  return entriesOn(day).slice(0, MAX_CHIPS)
}
function overflow(day: GridDay): number {
  return Math.max(0, entriesOn(day).length - MAX_CHIPS)
}
function typeLabel(r: TeamRow): string {
  return r.leave_type_key === 'away' ? 'Away' : r.leave_type_key.replace('_', ' ')
}
function tone(r: TeamRow): string {
  return LEAVE_TYPE_TONE[r.leave_type_key] ?? 'blue'
}
/** The full description — read by screen readers and shown on hover; the chip itself shows a short name. */
function label(r: TeamRow): string {
  const state = r.status === 'pending' ? ' (pending)' : r.cancellation_asked ? ' (cancel asked)' : ''
  const where = many.value ? ` · ${nameOf(r.company_id)}` : ''
  return `${r.full_name} · ${typeLabel(r)}${state}${where}`
}
function initials(name: string): string {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0]?.toUpperCase() ?? '').join('')
}

// ------------------------------------------------------------- the rail
// The day rail: what the clicked day is and who is away on it. A person's
// name links to their record only when the viewer may open it (their own,
// or leave.view / leave.approve in that company — the same rule the
// database applied when it decided whether to redact the row).
const selectedKind = computed(() => (selected.value ? dayKind(selected.value, holidays.value, closures.value) : 'working'))
const selectedLeaves = computed(() =>
  selected.value ? entriesOn({ iso: selected.value, day: 0, inMonth: true, weekend: selectedKind.value === 'weekend' }) : [],
)
const kindText: Record<string, { title: string; sub: string }> = {
  working: { title: 'Working day', sub: 'A normal day' },
  weekend: { title: 'Weekend', sub: 'Not a working day' },
  holiday: { title: 'Public holiday', sub: 'Does not count as leave' },
  closure: { title: 'Company closure', sub: 'Does not count as leave' },
}
function dayTitle(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' })
}
function canOpen(r: TeamRow): boolean {
  return r.person_id === auth.personId || r.leave_type_key !== 'away'
}
function progress(r: TeamRow): { text: string; pct: number } {
  const p = leaveProgress(r, selected.value ?? r.start_date)
  return { text: p.of === 1 ? 'one day' : `day ${p.day} of ${p.of}`, pct: Math.round((p.day / p.of) * 100) }
}
function select(day: GridDay): void {
  selected.value = selected.value === day.iso ? null : day.iso
}

// ---------------------------------------------------------------- load
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
  const tag = (name: string, t: string, tagged: boolean) => (tagged ? `${name} (${t})` : name)
  holidays.value = Object.fromEntries((holRes.data ?? []).map((h) => [h.date, tag(h.name, h.country_code, countries.value.length > 1)]))
  closures.value = Object.fromEntries((cloRes.data ?? []).map((c) => [c.date, tag(c.name, nameOf(c.company_id), many.value)]))
  loading.value = false
}

watch([() => props.companies, year, month], load)
onMounted(load)
</script>

<template>
  <div class="calendar">
    <div class="stats" data-testid="leave-stats">
      <div class="stat">
        <b>{{ stats.awayToday }}</b>
        <span>away today</span>
      </div>
      <div class="stat" :class="{ hot: stats.pending }">
        <b>{{ stats.pending }}</b>
        <span>pending {{ stats.pending === 1 ? 'request' : 'requests' }}</span>
      </div>
      <div class="stat">
        <b>{{ stats.peopleThisMonth }}</b>
        <span>{{ stats.peopleThisMonth === 1 ? 'person' : 'people' }} away in {{ monthLabel.split(' ')[0] }} · {{ stats.daysThisMonth }} working days</span>
      </div>
      <div class="stat">
        <b>{{ stats.holidays }}</b>
        <span>public {{ stats.holidays === 1 ? 'holiday' : 'holidays' }} this month</span>
      </div>
    </div>

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
          <button class="button secondary small-btn" type="button" :disabled="isCurrentMonth && selected === today" @click="goToday">Today</button>
          <button class="button secondary small-btn icon" type="button" aria-label="Previous month" @click="shift(-1)">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 3L5 8l5 5" /></svg>
          </button>
          <button class="button secondary small-btn icon" type="button" aria-label="Next month" @click="shift(1)">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 3l5 5-5 5" /></svg>
          </button>
        </div>
      </div>
      <div class="legend" aria-label="Legend">
        <span><i class="key green"></i>Annual</span>
        <span><i class="key amber"></i>Sick</span>
        <span><i class="key blue"></i>Other</span>
        <span v-if="!fullView"><i class="key grey"></i>Away</span>
        <span><i class="key pending"></i>Pending</span>
        <span><i class="key holiday"></i>Holiday / closure</span>
        <span><i class="key mine"></i>You</span>
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
            :class="{ out: !day.inMonth, weekend: day.weekend, today: day.iso === today, holiday: holidays[day.iso] || closures[day.iso], selected: day.iso === selected, busy: entriesOn(day).length }"
            :data-date="day.iso"
            role="button"
            tabindex="0"
            :aria-pressed="day.iso === selected"
            :aria-label="`${dayTitle(day.iso)}${holidays[day.iso] ? `, ${holidays[day.iso]}` : ''}${entriesOn(day).length ? `, ${entriesOn(day).length} away` : ''}`"
            @click="select(day)"
            @keydown.enter.prevent="select(day)"
            @keydown.space.prevent="select(day)"
          >
            <div class="day-head">
              <b class="num">{{ day.day }}</b>
              <small v-if="holidays[day.iso] || closures[day.iso]" class="hol" :title="holidays[day.iso] || closures[day.iso]">{{ holidays[day.iso] || closures[day.iso] }}</small>
            </div>
            <div class="chips">
              <div
                v-for="r in visibleChips(day)"
                :key="r.id"
                class="entry"
                :class="[tone(r), { pending: r.status === 'pending', mine: r.person_id === auth.personId }]"
                :title="label(r)"
              >
                <span class="chip-name">{{ shortName(r.full_name) }}</span>
                <span class="sr-only">{{ label(r) }}</span>
              </div>
              <div v-if="overflow(day)" class="more">+{{ overflow(day) }} more</div>
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
            <button class="button secondary small-btn icon" type="button" aria-label="Close day" @click="selected = null">
              <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8" /></svg>
            </button>
          </div>
          <div class="rail-count">
            <template v-if="selectedLeaves.length">
              <b>{{ selectedLeaves.length }}</b> {{ selectedLeaves.length === 1 ? 'person is' : 'people are' }} away
            </template>
            <template v-else-if="selectedKind !== 'working'">Nobody is away — not a working day.</template>
            <template v-else>Nobody is away — a full team.</template>
          </div>
          <ul class="rail-people">
            <li v-for="r in selectedLeaves" :key="r.id" :class="tone(r)">
              <span class="avatar small" aria-hidden="true">{{ initials(r.full_name) }}</span>
              <div class="who">
                <router-link v-if="canOpen(r)" :to="{ name: 'person', params: { personId: r.person_id } }"><b>{{ r.full_name }}</b></router-link>
                <b v-else>{{ r.full_name }}</b>
                <small>
                  <i class="key" :class="tone(r)"></i>{{ typeLabel(r) }}{{ r.status === 'pending' ? ' · pending' : '' }}{{ r.cancellation_asked ? ' · asks to cancel' : '' }}{{ many ? ` · ${nameOf(r.company_id)}` : '' }}
                </small>
                <small>{{ r.start_date }} → {{ r.end_date }} · {{ progress(r).text }}</small>
                <span class="bar" aria-hidden="true"><i :style="{ width: `${progress(r).pct}%` }"></i></span>
                <small v-if="r.note" class="note">“{{ r.note }}”</small>
              </div>
            </li>
          </ul>
        </aside>
      </div>
    </div>
  </div>
</template>

<style scoped>
.calendar { display: grid; gap: 18px; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; }
.stat { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 16px 20px; box-shadow: var(--shadow-sm); display: grid; gap: 2px; }
.stat b { font-size: 26px; font-weight: 700; letter-spacing: -0.03em; line-height: 1.1; }
.stat span { font-size: 12px; color: var(--muted); }
.stat.hot { border-color: #ead9b3; background: linear-gradient(135deg, #fff, #fdf7e9); }
.stat.hot b { color: var(--amber); }

.nav { display: flex; gap: 6px; }
.small-btn { padding: 7px 11px; font-size: 11px; }
.small-btn.icon { padding: 7px 9px; }
.in-card { margin: 14px 24px; }

.legend { display: flex; gap: 16px; flex-wrap: wrap; padding: 10px 24px; font-size: 11px; color: var(--muted); border-bottom: 1px solid var(--line); background: #fbfcfa; }
.legend span { display: inline-flex; align-items: center; gap: 6px; }
.key { display: inline-block; width: 9px; height: 9px; border-radius: 3px; background: #c9cfc5; flex-shrink: 0; }
.key.green { background: #3a8a63; }
.key.amber { background: #d29a2f; }
.key.blue { background: #5a7fb8; }
.key.grey { background: #9aa39c; }
.key.pending { background: transparent; border: 1.5px dashed #8a9488; }
.key.holiday { background: #f2dcae; }
.key.mine { background: transparent; box-shadow: inset 0 0 0 2px var(--green-bright); }

.layout { display: grid; grid-template-columns: 1fr; }
.layout.open { grid-template-columns: minmax(0, 1fr) 300px; }
.grid { display: grid; grid-template-columns: repeat(7, 1fr); }
.dow { font-size: 10px; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); padding: 10px 10px 8px; background: #fafbf8; font-weight: 650; }
.day { min-height: 112px; padding: 8px 8px 10px; border-top: 1px solid var(--line); border-left: 1px solid var(--line); font-size: 11px; cursor: pointer; transition: background 0.15s var(--ease), box-shadow 0.15s var(--ease); position: relative; }
.day:nth-child(7n + 1) { border-left: 0; }
.day:hover { background: #f7f9f5; }
.day.out { color: #b5bcb1; background: #fcfcfb; }
.day.out .entry { opacity: 0.55; }
.day.weekend { background: #f6f7f4; }
.day.holiday { background: linear-gradient(180deg, #fdf5e4, #fbf2df); }
.day.selected { box-shadow: inset 0 0 0 2px var(--green-bright); z-index: 1; }
.day.today .num { color: #fff; background: var(--green-bright); }
.day-head { display: flex; align-items: center; gap: 6px; min-width: 0; }
.num { display: grid; place-items: center; width: 22px; height: 22px; border-radius: 50%; font-size: 11px; font-weight: 650; flex-shrink: 0; }
.hol { font-size: 10px; color: #8a5e21; font-weight: 650; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.chips { display: grid; gap: 3px; margin-top: 6px; }
.entry { display: flex; align-items: center; gap: 5px; font-size: 11px; font-weight: 550; padding: 3px 6px; border-radius: 6px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; border: 1px solid transparent; line-height: 1.2; }
.entry::before { content: ''; width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; background: currentColor; }
.entry.green { background: #e6f2e9; color: #2c6144; }
.entry.amber { background: #fbf1da; color: var(--amber); }
.entry.blue { background: #e8eef8; color: #3f5f8f; }
.entry.grey { background: #eceeea; color: #4f5b55; }
.entry.pending { background: #fff; border-style: dashed; border-color: currentColor; opacity: 0.85; }
.entry.mine { box-shadow: inset 0 0 0 1.5px var(--green-bright); }
.chip-name { overflow: hidden; text-overflow: ellipsis; }
.more { font-size: 10px; color: var(--muted); font-weight: 600; padding: 2px 6px; }
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }

.rail { border-top: 1px solid var(--line); border-left: 1px solid var(--line); padding: 16px 18px; font-size: 12px; background: #fbfcfa; }
.rail-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 8px; }
.rail-head strong { display: block; font-size: 15px; margin-top: 4px; }
.rail-head small { display: block; color: var(--muted); font-size: 11px; }
.rail-count { margin: 14px 0 10px; font-size: 12px; }
.rail-people { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
.rail-people li { display: flex; gap: 10px; align-items: flex-start; border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; background: #fff; box-shadow: var(--shadow-sm); }
.rail-people .who { display: grid; gap: 3px; min-width: 0; flex: 1; }
.rail-people .who > a { text-decoration: none; }
.rail-people small { color: var(--muted); font-size: 11px; display: flex; align-items: center; gap: 5px; }
.rail-people .note { color: var(--ink); display: block; }
.avatar.small { width: 30px; height: 30px; font-size: 11px; }
.bar { display: block; height: 4px; border-radius: 4px; background: #e9eee6; overflow: hidden; margin: 2px 0; }
.bar i { display: block; height: 100%; background: linear-gradient(90deg, var(--green-bright), var(--green)); border-radius: 4px; transition: width 0.3s var(--ease); }
.rail-people li.amber .bar i { background: linear-gradient(90deg, #d29a2f, var(--amber)); }
.rail-people li.blue .bar i { background: linear-gradient(90deg, #5a7fb8, #3f5f8f); }
@media (max-width: 720px) {
  .layout.open { grid-template-columns: 1fr; }
  .rail { border-left: 0; }
  .day { min-height: 64px; padding: 6px; }
  .entry { font-size: 10px; }
}
</style>
