<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { todayDb } from '@/lib/compensation'
import CompanyFilter from '@/components/CompanyFilter.vue'
import { expandForImport, parseHolidayProgramme, restrictToYear, rollForwardYear, type ParseResult } from '@/lib/holidayImport'

/**
 * Holiday calendars (plan 036): one statutory list per country, pasted from
 * the official programme (parser ported from Field Notebook — substitute
 * days become their own rows), plus closures that apply to one company.
 * Writes need holidays.manage (RLS); everyone may read.
 */

type Holiday = { id: string; country_code: string; date: string; name: string; kind: string; observed_of: string | null }
type Closure = { id: string; company_id: string; date: string; name: string }
type Company = { id: string; name: string; country_code: string | null }

const props = defineProps<{ companies: Company[] }>()

const auth = useAuthStore()
const dialogs = useDialogStore()
const thisYear = Number(todayDb().slice(0, 4))
const year = ref(thisYear)
const country = ref('MK')
const holidays = ref<Holiday[]>([])
const closures = ref<Closure[]>([])
const closureCompany = ref(props.companies[0]?.id ?? '')
const loading = ref(true)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const pasted = ref('')
const parsed = ref<ParseResult | null>(null)
const newHoliday = ref({ date: '', name: '' })
const newClosure = ref({ date: '', name: '' })

const canManage = computed(() => auth.isAdmin || Object.values(auth.capabilities).some((set) => set.has('holidays.manage')))
const countries = computed(() => {
  const known = new Set(['MK', 'RS', 'MT'])
  for (const c of props.companies) if (c.country_code) known.add(c.country_code)
  for (const h of holidays.value) known.add(h.country_code)
  return Array.from(known).sort()
})
const years = computed(() => [thisYear - 1, thisYear, thisYear + 1])
const yearHolidays = computed(() => holidays.value.filter((h) => h.country_code === country.value && h.date.startsWith(String(year.value))))
const yearClosures = computed(() => closures.value.filter((c) => c.company_id === closureCompany.value && c.date.startsWith(String(year.value))))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [holRes, cloRes] = await Promise.all([
    supabase.from('public_holidays').select('id, country_code, date, name, kind, observed_of').order('date'),
    supabase.from('company_closures').select('id, company_id, date, name').order('date'),
  ])
  if (holRes.error || cloRes.error) {
    error.value = 'Could not load the calendars.'
    console.error('Holidays load failed:', holRes.error?.message ?? cloRes.error?.message)
  } else {
    holidays.value = holRes.data ?? []
    closures.value = cloRes.data ?? []
  }
  loading.value = false
}

async function write(p: PromiseLike<{ error: { message: string } | null }>, done: string): Promise<void> {
  error.value = null
  const res = await p
  if (res.error) {
    error.value = /row-level security/i.test(res.error.message) ? 'You need the "Manage holidays" capability.' : res.error.message
    console.error('Calendar write failed:', res.error.message)
    return
  }
  notice.value = done
  await load()
}

function addHoliday(): void {
  if (!newHoliday.value.date || !newHoliday.value.name.trim()) {
    error.value = 'Give the holiday a date and a name.'
    return
  }
  void write(
    supabase.from('public_holidays').upsert(
      { country_code: country.value, date: newHoliday.value.date, name: newHoliday.value.name.trim(), kind: 'statutory' },
      { onConflict: 'country_code,date' },
    ),
    'Holiday saved.',
  ).then(() => (newHoliday.value = { date: '', name: '' }))
}

async function removeHoliday(h: Holiday): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Remove ${h.name} (${h.date})?`,
    hint: `It leaves the ${h.country_code} statutory calendar; leave requests count it as a working day from now on.`,
    confirmLabel: 'Remove holiday',
    danger: true,
  })
  if (!ok) return
  await write(supabase.from('public_holidays').delete().eq('id', h.id), 'Holiday removed.')
}

function preview(): void {
  parsed.value = restrictToYear(parseHolidayProgramme(pasted.value, year.value), year.value)
}

function importParsed(): void {
  if (!parsed.value?.entries.length) return
  const rows = expandForImport(parsed.value.entries).map((r) => ({ ...r, country_code: country.value, kind: 'statutory' }))
  void write(supabase.from('public_holidays').upsert(rows, { onConflict: 'country_code,date' }), `${rows.length} holidays imported for ${country.value} ${year.value}.`).then(() => {
    parsed.value = null
    pasted.value = ''
  })
}

function rollForward(): void {
  const from = year.value - 1
  const source = holidays.value.filter((h) => h.country_code === country.value)
  const result = rollForwardYear(source, from, year.value)
  parsed.value = { entries: result.entries, unparsed: result.needsReview, sectionWarnings: [] }
}

function addClosure(): void {
  if (!newClosure.value.date || !newClosure.value.name.trim()) {
    error.value = 'Give the closure a date and a name.'
    return
  }
  void write(
    supabase.from('company_closures').upsert(
      { company_id: closureCompany.value, date: newClosure.value.date, name: newClosure.value.name.trim() },
      { onConflict: 'company_id,date' },
    ),
    'Closure saved.',
  ).then(() => (newClosure.value = { date: '', name: '' }))
}

async function removeClosure(c: Closure): Promise<void> {
  const company = props.companies.find((x) => x.id === c.company_id)?.name ?? 'the company'
  const ok = await dialogs.confirmAction({
    title: `Remove ${c.name} (${c.date})?`,
    hint: `${company} is open that day again; leave requests count it as a working day from now on.`,
    confirmLabel: 'Remove closure',
    danger: true,
  })
  if (!ok) return
  await write(supabase.from('company_closures').delete().eq('id', c.id), 'Closure removed.')
}

watch([year, country], () => (parsed.value = null))
onMounted(load)
</script>

<template>
  <div>
    <p v-if="error" class="error-note section" role="alert">{{ error }}</p>
    <p v-if="notice" class="notice section" role="status">{{ notice }}</p>
    <div class="card section">
      <div class="card-head">
        <div>
          <h2>Statutory holidays</h2>
          <p>One list per country. Everyone employed in that country gets these days off; they never count as leave.</p>
        </div>
        <div class="head-actions">
          <select v-model="country" aria-label="Country" class="pick">
            <option v-for="c in countries" :key="c" :value="c">{{ c }}</option>
          </select>
          <select v-model="year" aria-label="Year" class="pick">
            <option v-for="y in years" :key="y" :value="y">{{ y }}</option>
          </select>
        </div>
      </div>
      <div v-if="loading" class="empty">Loading…</div>
      <template v-else>
        <div v-if="!yearHolidays.length" class="empty">No {{ country }} holidays for {{ year }} yet.</div>
        <div class="table-wrap" v-else>
          <table>
            <thead><tr><th>Date</th><th>Holiday</th><th v-if="canManage"></th></tr></thead>
            <tbody>
              <tr v-for="h in yearHolidays" :key="h.id">
                <td>{{ h.date }}</td>
                <td>{{ h.name }}<small v-if="h.observed_of" class="muted"> · observed for {{ h.observed_of }}</small></td>
                <td v-if="canManage" class="right"><button class="button secondary small-btn" type="button" @click="removeHoliday(h)">Remove</button></td>
              </tr>
            </tbody>
          </table>
        </div>
        <div v-if="canManage" class="manage">
          <form class="inline" @submit.prevent="addHoliday">
            <input v-model="newHoliday.date" type="date" aria-label="Holiday date" required />
            <input v-model="newHoliday.name" placeholder="Holiday name" aria-label="Holiday name" maxlength="120" required />
            <button class="button small-btn" type="submit">Add holiday</button>
          </form>
          <details class="import">
            <summary>Paste the official programme for {{ country }} {{ year }}</summary>
            <textarea v-model="pasted" rows="6" placeholder="One holiday per line — '1 January, New Year' or '24 мај (недела) …, односно 25 мај …'"></textarea>
            <div class="inline">
              <button class="button secondary small-btn" type="button" @click="preview">Preview</button>
              <button class="button secondary small-btn" type="button" :title="`Carry ${year - 1}'s fixed dates into ${year}`" @click="rollForward">Roll {{ year - 1 }} forward</button>
              <button v-if="parsed?.entries.length" class="button small-btn" type="button" @click="importParsed">Import {{ parsed.entries.length }}</button>
            </div>
            <div v-if="parsed" class="preview">
              <p v-for="w in parsed.sectionWarnings" :key="w" class="warn">{{ w }}</p>
              <ul>
                <li v-for="e in parsed.entries" :key="e.date + e.name">
                  {{ e.date }} — {{ e.name }}<span v-if="e.observedDate"> (observed {{ e.observedDate }})</span>
                  <span v-if="e.warning" class="warn"> · {{ e.warning }}</span>
                </li>
              </ul>
              <p v-if="parsed.unparsed.length" class="warn">Not read: {{ parsed.unparsed.join(' | ') }}</p>
            </div>
          </details>
        </div>
      </template>
    </div>

    <div class="card section">
      <div class="card-head">
        <div>
          <h2>Company closures</h2>
          <p>Days one company is closed — a collective day off that applies to that company only.</p>
        </div>
        <CompanyFilter v-model="closureCompany" :companies="companies" />
      </div>
      <div v-if="!yearClosures.length" class="empty">No closures in {{ year }}.</div>
      <div class="table-wrap" v-else>
        <table>
          <thead><tr><th>Date</th><th>Closure</th><th v-if="canManage"></th></tr></thead>
          <tbody>
            <tr v-for="c in yearClosures" :key="c.id">
              <td>{{ c.date }}</td>
              <td>{{ c.name }}</td>
              <td v-if="canManage" class="right"><button class="button secondary small-btn" type="button" @click="removeClosure(c)">Remove</button></td>
            </tr>
          </tbody>
        </table>
      </div>
      <form v-if="canManage" class="inline manage" @submit.prevent="addClosure">
        <input v-model="newClosure.date" type="date" aria-label="Closure date" required />
        <input v-model="newClosure.name" placeholder="e.g. Office closed between the holidays" aria-label="Closure name" maxlength="120" required />
        <button class="button small-btn" type="submit">Add closure</button>
      </form>
    </div>
  </div>
</template>

<style scoped>
.section { margin-bottom: 22px; }
.notice { padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.head-actions { display: flex; gap: 8px; }
.pick { border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; background: #fff; }
.small-btn { padding: 7px 11px; font-size: 11px; }
.right { text-align: right; }
.muted { color: var(--muted); }
.manage { padding: 16px 24px; border-top: 1px solid #edf0eb; display: grid; gap: 14px; }
.inline { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.inline input { border: 1px solid #dce3d7; padding: 9px 11px; font-size: 12px; }
.inline input[type='date'] { width: 160px; }
.import summary { cursor: pointer; font-size: 12px; font-weight: 550; }
textarea { width: 100%; border: 1px solid #dce3d7; padding: 10px 12px; font-size: 12px; margin: 10px 0; font-family: inherit; }
.preview { font-size: 11px; margin-top: 10px; }
.preview ul { margin: 6px 0; padding-left: 18px; }
.warn { color: #946d24; }
</style>
