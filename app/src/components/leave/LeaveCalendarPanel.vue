<script setup lang="ts">
import { dayHeadline, dayStanding, leaveStanding, type DayKind } from '@/lib/leaveDay'
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { todayDb } from '@/lib/compensation'
import { LEAVE_TYPE_TONE, dayKind, leaveProgressWorking, monthGrid, shortDate, shortName, type GridDay } from '@/lib/leave'

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
// A day already past is described as such. "Working day · A normal day" on last
// Thursday reads as the app describing the calendar, not what happened.
const selectedStanding = computed(() => (selected.value ? dayStanding(selected.value, todayIso()) : 'today'))
const kindLine = computed(() => dayHeadline(selectedKind.value as DayKind, selectedStanding.value))
function dayTitle(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' })
}
const detail = ref<TeamRow | null>(null)
function todayIso(): string { return new Date().toISOString().slice(0, 10) }
/** Where this leave stands TODAY, not on the day being looked at. */
function standingOf(r: TeamRow) { return leaveStanding({ start: r.start_date, end: r.end_date }, todayIso()) }

function canOpen(r: TeamRow): boolean {
  return r.person_id === auth.personId || r.leave_type_key !== 'away'
}
/** Where the leave stands on the clicked day, in working days (the unit the request and balance use). */
function progress(r: TeamRow): { text: string; pct: number } {
  const p = leaveProgressWorking(r, selected.value ?? r.start_date, Object.keys(holidays.value), Object.keys(closures.value))
  if (p.of <= 1) return { text: 'one working day', pct: 100 }
  const left = p.left === 0 ? 'last day' : `${p.left} left`
  return { text: `working day ${p.day} of ${p.of} · ${left}`, pct: Math.round((p.day / p.of) * 100) }
}
const selectedDayNumber = computed(() => (selected.value ? Number(selected.value.slice(8, 10)) : 0))
const selectedWeekday = computed(() =>
  selected.value ? new Date(`${selected.value}T00:00:00Z`).toLocaleDateString('en-GB', { weekday: 'long', timeZone: 'UTC' }) : '',
)
const selectedMonthYear = computed(() =>
  selected.value ? new Date(`${selected.value}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' }) : '',
)
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
  const teamRes = await Promise.all(
    props.companies.map((c) => supabase.rpc('team_leave', { p_company_id: c.id, p_from: first, p_to: last }).then((r) => ({ ...r, company: c }))),
  )
  const failed = teamRes.find((r) => r.error)
  if (failed?.error) {
    error.value = failed.error.message
    console.error('team_leave failed:', failed.error.message)
  } else {
    rows.value = teamRes.flatMap((r) => ((r.data ?? []) as Omit<TeamRow, 'company_id'>[]).map((row) => ({ ...row, company_id: r.company.id })))
  }
  // Days off for the whole span of the leaves on screen — a leave that began
  // last month is counted with last month's holidays too.
  const from = rows.value.reduce((min, r) => (r.start_date < min ? r.start_date : min), first)
  const to = rows.value.reduce((max, r) => (r.end_date > max ? r.end_date : max), last)
  const [holRes, cloRes] = await Promise.all([
    countries.value.length
      ? supabase.from('public_holidays').select('date, name, country_code').in('country_code', countries.value).gte('date', from).lte('date', to)
      : Promise.resolve({ data: [] as { date: string; name: string; country_code: string }[], error: null }),
    supabase.from('company_closures').select('date, name, company_id').in('company_id', props.companies.map((c) => c.id)).gte('date', from).lte('date', to),
  ])
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
              <span class="eyebrow">{{ selectedWeekday }}</span>
              <strong class="day-number">{{ selectedDayNumber }}</strong>
              <small>{{ selectedMonthYear }}</small>
            </div>
            <button class="button secondary small-btn icon" type="button" aria-label="Close day" @click="selected = null">
              <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8" /></svg>
            </button>
          </div>
          <div class="rail-kind" :class="[selectedKind, selectedStanding]">
            <svg v-if="selectedKind === 'holiday' || selectedKind === 'closure'" width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 2v3M3.8 3.8l2 2M12.2 3.8l-2 2M2 8h3M11 8h3M8 8l4.5 6H3.5z" /></svg>
            <svg v-else-if="selectedKind === 'weekend'" width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2" y="3" width="12" height="11" rx="2" /><path d="M2 7h12M5 2v2M11 2v2M6 10l4 2M10 10l-4 2" /></svg>
            <svg v-else width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="8" cy="8" r="3" /><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4" /></svg>
            <span>
              <b>{{ holidays[selected] || closures[selected] || kindLine.title }}</b>
              <small>{{ selectedKind === 'holiday' ? 'Public holiday · does not count as leave' : selectedKind === 'closure' ? 'Company closure · does not count as leave' : kindLine.sub }}</small>
            </span>
          </div>
          <div class="rail-count">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="6" cy="5.5" r="2.5" /><path d="M1.5 13.5c0-2.5 2-4 4.5-4s4.5 1.5 4.5 4M11 4a2.2 2.2 0 0 1 0 4.4M12.5 9.6c1.4.5 2 1.7 2 3.4" /></svg>
            <template v-if="selectedLeaves.length">
              <span>
                <b>{{ selectedLeaves.length }}</b>
                {{ selectedLeaves.length === 1 ? 'person' : 'people' }}
                {{ selectedStanding === 'past' ? (selectedLeaves.length === 1 ? 'was' : 'were') : (selectedLeaves.length === 1 ? 'is' : 'are') }}
                away
              </span>
            </template>
            <span v-else-if="selectedKind !== 'working'">Nobody away — not a working day.</span>
            <span v-else>Nobody away — a full team.</span>
          </div>
          <ul class="rail-people">
            <li v-for="r in selectedLeaves" :key="r.id" :class="[tone(r), 'clickable']" tabindex="0" role="button"
                :aria-label="`Open ${r.full_name}'s leave`"
                @click="detail = r" @keydown.enter="detail = r" @keydown.space.prevent="detail = r">
              <i class="dot" aria-hidden="true"></i>
              <div class="who">
                <router-link v-if="canOpen(r)" :to="{ name: 'person', params: { personId: r.person_id } }"><b>{{ r.full_name }}</b></router-link>
                <b v-else>{{ r.full_name }}</b>
                <small>{{ typeLabel(r) }}{{ r.status === 'pending' ? ' · pending' : '' }}{{ r.cancellation_asked ? ' · asks to cancel' : '' }}{{ many ? ` · ${nameOf(r.company_id)}` : '' }}</small>
                <small>{{ shortDate(r.start_date) }} → {{ shortDate(r.end_date) }} · {{ r.working_days }} working {{ Number(r.working_days) === 1 ? 'day' : 'days' }}</small>
                <span class="progress">
                  <span class="bar" aria-hidden="true"><i :style="{ width: `${standingOf(r) === 'finished' ? 100 : progress(r).pct}%` }"></i></span>
                  <small>{{ standingOf(r) === 'finished' ? `taken in full · ${r.working_days} working ${Number(r.working_days) === 1 ? 'day' : 'days'}` : progress(r).text }}</small>
                </span>
                <small v-if="r.note" class="note">“{{ r.note }}”</small>
              </div>
            </li>
          </ul>
        </aside>
      </div>
    </div>

    <dialog v-if="detail" class="leave-detail" open @click.self="detail = null">
      <div class="detail-card">
        <div class="detail-head">
          <div>
            <strong>{{ detail.full_name }}</strong>
            <small>{{ typeLabel(detail) }}{{ many ? ` · ${nameOf(detail.company_id)}` : '' }}</small>
          </div>
          <button class="button secondary small-btn" type="button" @click="detail = null">Close</button>
        </div>
        <dl class="detail-facts">
          <div><dt>From</dt><dd>{{ detail.start_date }}</dd></div>
          <div><dt>To</dt><dd>{{ detail.end_date }}</dd></div>
          <div><dt>Working days</dt><dd>{{ detail.working_days }}</dd></div>
          <div>
            <dt>Standing today</dt>
            <dd>{{ standingOf(detail) === 'finished' ? 'Taken in full' : standingOf(detail) === 'running' ? 'Away now' : 'Not started' }}</dd>
          </div>
          <div><dt>Status</dt><dd>{{ detail.status }}{{ detail.cancellation_asked ? ' · asks to cancel' : '' }}</dd></div>
          <div v-if="selected"><dt>On {{ selected }}</dt><dd>{{ progress(detail).text }}</dd></div>
        </dl>
        <p v-if="detail.note" class="detail-note">“{{ detail.note }}”</p>
        <router-link
          v-if="canOpen(detail)"
          class="button small-btn"
          :to="{ name: 'person', params: { personId: detail.person_id } }"
        >Open their record</router-link>
      </div>
    </dialog>
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
.layout.open { grid-template-columns: minmax(0, 1fr) minmax(280px, 340px); gap: 18px; }
.grid { display: grid; grid-template-columns: repeat(7, 1fr); align-content: start; }
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

.rail { border-top: 1px solid var(--line); border-left: 1px solid var(--line); padding: 20px 20px 22px; font-size: 12px; background: #fbfcfa; }
.rail-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
.rail-head > div { display: grid; gap: 2px; }
.day-number { font-size: 46px; line-height: 0.9; font-weight: 700; letter-spacing: -0.05em; color: var(--ink); margin-top: 6px; }
.rail-head small { color: var(--muted); font-size: 11.5px; margin-top: 4px; }
.rail-kind { display: flex; align-items: center; gap: 9px; margin-top: 18px; padding: 11px 12px; border-left: 3px solid; border-radius: 0 8px 8px 0; }
.rail-kind span { display: grid; gap: 1px; min-width: 0; }
.rail-kind b { font-size: 12.5px; }
.rail-kind small { font-size: 10.5px; opacity: 0.85; }
.rail-kind.working { color: var(--green-deep); background: #e9f0eb; border-color: var(--green); }
.rail-kind.weekend { color: #5f6b62; background: #eef0ea; border-color: #9aafa4; }
.rail-kind.holiday, .rail-kind.closure { color: #8a5e21; background: #f5ead8; border-color: #c08a3a; }
.rail-count { display: flex; align-items: center; gap: 7px; margin: 16px 0 0; color: var(--muted); font-size: 12.5px; }
.rail-count b { color: var(--green); font-size: 15px; }
.rail-people { list-style: none; margin: 13px 0 0; padding: 0; display: grid; gap: 6px; }
.rail-people li.clickable { cursor: pointer; }
.rail-people li.clickable:hover, .rail-people li.clickable:focus-visible { border-color: var(--green); background: #f7f9f5; }
.rail-kind.past { opacity: 0.85; }
.rail-kind.past b { color: #8a6d1f; }
.leave-detail { position: fixed; inset: 0; width: 100%; height: 100%; max-width: none; max-height: none; border: 0; background: rgba(20, 28, 20, 0.35); display: grid; place-items: center; padding: 20px; z-index: 50; }
.detail-card { background: #fff; border-radius: 14px; padding: 20px 22px; width: min(460px, 100%); display: grid; gap: 14px; box-shadow: 0 18px 50px rgba(20, 28, 20, 0.18); }
.detail-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
.detail-head strong { display: block; font-size: 15px; font-weight: 650; }
.detail-head small { display: block; font-size: 11px; color: var(--muted); margin-top: 2px; }
.detail-facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(110px, 1fr)); gap: 12px; margin: 0; }
.detail-facts dt { font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
.detail-facts dd { margin: 3px 0 0; font-size: 12px; font-weight: 550; }
.detail-note { margin: 0; font-size: 12px; color: var(--muted); font-style: italic; }
.rail-people li { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 10px; border: 1px solid var(--line); border-radius: 8px; padding: 10px 11px; background: #fff; transition: border-color 0.18s var(--ease), background 0.18s var(--ease); }
.rail-people li:hover { border-color: var(--green); background: #f4f8f3; }
.rail-people .dot { width: 9px; height: 9px; margin-top: 5px; border-radius: 50%; background: #9aa39c; }
.rail-people li.green .dot { background: #3a8a63; }
.rail-people li.amber .dot { background: #d29a2f; }
.rail-people li.blue .dot { background: #5a7fb8; }
.rail-people .who { display: grid; gap: 2px; min-width: 0; }
.rail-people .who > a { text-decoration: none; color: var(--ink); }
.rail-people .who > a:hover b { color: var(--green); }
.rail-people b { font-size: 12.5px; }
.rail-people small { color: var(--muted); font-size: 11px; }
.rail-people .note { color: var(--ink); margin-top: 2px; }
.progress { display: grid; gap: 4px; margin-top: 5px; }
.bar { display: block; height: 3px; border-radius: 3px; background: #e6ebe3; overflow: hidden; }
.bar i { display: block; height: 100%; background: var(--green); border-radius: 3px; transition: width 0.3s var(--ease); }
.rail-people li.amber .bar i { background: var(--amber); }
.rail-people li.blue .bar i { background: #3f5f8f; }
/* Below this the calendar and the rail each need the whole width; sharing it
   left seven day columns and a list of names both too narrow to read. */
@media (max-width: 1080px) {
  .layout.open { grid-template-columns: 1fr; }
  .rail { position: static; max-height: none; }
}
@media (max-width: 720px) {
  .layout.open { grid-template-columns: 1fr; }
  .rail { border-left: 0; }
  .day { min-height: 64px; padding: 6px; }
  .entry { font-size: 10px; }
}
</style>
