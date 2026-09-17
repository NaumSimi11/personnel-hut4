<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { todayDb } from '@/lib/compensation'
import { EMPTY_OVERVIEW, MESSAGE_MAX, kudosInput, monthLabel, monthOptions, type KudosAdminRow, type KudosForm, type KudosOverview } from '@/lib/kudos'
import { EMPLOYED_STATUSES } from '@/lib/leave'
import { shortDate } from '@/lib/leave'
import KudosValuesPanel from '@/components/kudos/KudosValuesPanel.vue'
import type { Json } from '@/types/database'

/**
 * The Kudos page (plan 051, the prototype's Admin tab): the kudos the
 * viewer manages — admins all of them, HR those given to people employed
 * where they hold people.view — by month, with the counts per value; a
 * kudos recorded on a colleague's behalf with a date; edit and remove.
 * The values themselves are the admins'. Rules: migration 0044.
 */
type Person = { id: string; full_name: string }

const auth = useAuthStore()
const dialogs = useDialogStore()
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const overview = ref<KudosOverview>(EMPTY_OVERVIEW)
const month = ref('')
const givers = ref<Person[]>([])
const receivers = ref<Person[]>([])
const adding = ref(false)
const editingId = ref<string | null>(null)
const form = ref<KudosForm>({ from_person_id: '', to_person_id: '', message: '', value_id: '', on_date: todayDb() })

const options = computed(() => monthOptions(overview.value.months, overview.value.total))
const activeValues = computed(() => overview.value.values.filter((v) => v.active))
const monthText = computed(() => (month.value ? monthLabel(month.value) : 'all months'))

async function loadOverview(): Promise<void> {
  const { data, error: err } = await supabase.rpc('kudos_overview', { p_month: month.value || undefined })
  if (err) {
    error.value = 'Could not load the kudos.'
    console.error('Kudos overview load failed:', err.message)
    return
  }
  overview.value = { ...EMPTY_OVERVIEW, ...(data as Partial<KudosOverview>) }
}

async function loadPeople(): Promise<void> {
  const [allRes, employedRes] = await Promise.all([
    supabase.from('people').select('id, full_name').is('archived_at', null).order('full_name'),
    supabase.from('employment_periods').select('company_id, person:people!employment_periods_person_id_fkey(id, full_name)').in('status', EMPLOYED_STATUSES),
  ])
  if (allRes.error) console.error('Kudos people load failed:', allRes.error.message)
  if (employedRes.error) console.error('Kudos employed load failed:', employedRes.error.message)
  givers.value = (allRes.data ?? []) as Person[]
  // Receivers: the people whose kudos the viewer manages — employed where they hold people.view.
  const seen = new Map<string, Person>()
  for (const row of (employedRes.data ?? []) as unknown as { company_id: string; person: Person | null }[]) {
    if (row.person && (auth.isAdmin || auth.can(row.company_id, 'people.view'))) seen.set(row.person.id, row.person)
  }
  receivers.value = [...seen.values()].sort((a, b) => a.full_name.localeCompare(b.full_name))
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  await Promise.all([loadOverview(), loadPeople()])
  loading.value = false
}

async function changeMonth(): Promise<void> {
  await loadOverview()
}

function startAdd(): void {
  form.value = { from_person_id: auth.personId ?? '', to_person_id: '', message: '', value_id: '', on_date: todayDb() }
  editingId.value = null
  adding.value = true
  error.value = null
  notice.value = null
}

function startEdit(k: KudosAdminRow): void {
  form.value = { from_person_id: k.from_person_id, to_person_id: k.to_person_id, message: k.message, value_id: k.value_id ?? '', on_date: k.created_at.slice(0, 10) }
  editingId.value = k.id
  adding.value = false
  error.value = null
  notice.value = null
}

function cancel(): void {
  adding.value = false
  editingId.value = null
}

function friendly(message: string, code?: string): string {
  if (code === '42501') return message
  if (/retired/.test(message)) return 'That value is retired; pick an active one.'
  return message
}

async function submit(): Promise<void> {
  const parsed = kudosInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  error.value = null
  const payload = parsed.data as unknown as Json
  const { error: err } = editingId.value
    ? await supabase.rpc('update_kudos', { p_id: editingId.value, p: payload })
    : await supabase.rpc('record_kudos', { p: payload })
  busy.value = false
  if (err) {
    error.value = friendly(err.message, err.code)
    console.error('Kudos save failed:', err.message)
    return
  }
  const to = receivers.value.find((p) => p.id === parsed.data.to_person_id)?.full_name ?? 'the colleague'
  notice.value = editingId.value ? 'Kudos updated.' : `Kudos to ${to} is on the wall.`
  cancel()
  await loadOverview()
}

async function remove(k: KudosAdminRow): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Remove the kudos from ${k.from_name} to ${k.to_name}?`,
    hint: k.message,
    confirmLabel: 'Remove',
  })
  if (!ok) return
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err, count } = await supabase.from('kudos').delete({ count: 'exact' }).eq('id', k.id)
  busy.value = false
  if (err || !count) {
    error.value = 'Could not remove the kudos.'
    if (err) console.error('Kudos delete failed:', err.message)
    return
  }
  await loadOverview()
}

onMounted(load)
</script>

<template>
  <section class="page" aria-labelledby="kudos-heading" data-testid="kudos-page">
    <div class="page-head">
      <div>
        <div class="eyebrow">Kudos</div>
        <h1 id="kudos-heading">What the holding recognises, and who got thanked.</h1>
        <p class="page-sub">The kudos posted across the teams you look after, by month and by value; record one on a colleague's behalf when it was said in person.</p>
      </div>
      <button v-if="!adding" class="button" type="button" data-testid="kudos-add" @click="startAdd">Add kudos</button>
    </div>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <output v-if="notice" class="notice" data-testid="kudos-notice">{{ notice }}</output>

    <div class="grid">
      <div class="col">
        <form v-if="adding" class="card form-card" novalidate data-testid="kudos-admin-form" @submit.prevent="submit">
          <div class="card-head"><div><h2>Add kudos</h2><p>On a colleague's behalf, dated when it happened.</p></div></div>
          <div class="form">
            <label><span>From</span>
              <select id="ka-from" v-model="form.from_person_id">
                <option value="">— Choose —</option>
                <option v-for="p in givers" :key="p.id" :value="p.id">{{ p.full_name }}</option>
              </select>
            </label>
            <label><span>To</span>
              <select id="ka-to" v-model="form.to_person_id">
                <option value="">— Choose —</option>
                <option v-for="p in receivers" :key="p.id" :value="p.id">{{ p.full_name }}</option>
              </select>
            </label>
            <label><span>Date</span><input id="ka-date" v-model="form.on_date" type="date" :max="todayDb()" /></label>
            <label><span>Value</span>
              <select id="ka-value" v-model="form.value_id">
                <option value="">— No specific value —</option>
                <option v-for="v in activeValues" :key="v.id" :value="v.id">{{ v.name }}</option>
              </select>
            </label>
            <label class="wide"><span>Message</span><input id="ka-message" v-model="form.message" :maxlength="MESSAGE_MAX" placeholder="What did they do well?" /></label>
            <div class="form-actions">
              <button type="button" class="button secondary" :disabled="busy" @click="cancel">Cancel</button>
              <button type="submit" class="button" :disabled="busy">{{ busy ? 'Saving…' : 'Add kudos' }}</button>
            </div>
          </div>
        </form>

        <div class="card">
          <div class="card-head">
            <div>
              <h2>Kudos management</h2>
              <p>{{ overview.rows.length }} in {{ monthText }}<template v-if="overview.untagged"> · {{ overview.untagged }} without a value</template></p>
            </div>
            <select v-model="month" aria-label="Month" data-testid="kudos-month" @change="changeMonth">
              <option v-for="o in options" :key="o.value" :value="o.value">{{ o.label }}</option>
            </select>
          </div>
          <div v-if="loading" class="empty">Loading…</div>
          <div v-else-if="!overview.rows.length" class="empty">{{ month ? `No kudos in ${monthLabel(month)}.` : 'No kudos yet — add one, or wait for the team to post from Home.' }}</div>
          <template v-else>
            <template v-for="k in overview.rows" :key="k.id">
              <form v-if="editingId === k.id" class="form edit" novalidate data-testid="kudos-edit-form" @submit.prevent="submit">
                <label><span>From</span>
                  <select v-model="form.from_person_id">
                    <option v-for="p in givers" :key="p.id" :value="p.id">{{ p.full_name }}</option>
                  </select>
                </label>
                <label><span>To</span>
                  <select v-model="form.to_person_id">
                    <option v-for="p in receivers" :key="p.id" :value="p.id">{{ p.full_name }}</option>
                  </select>
                </label>
                <label><span>Date</span><input v-model="form.on_date" type="date" :max="todayDb()" /></label>
                <label><span>Value</span>
                  <select v-model="form.value_id">
                    <option value="">— No specific value —</option>
                    <option v-for="v in activeValues" :key="v.id" :value="v.id">{{ v.name }}</option>
                    <option v-if="k.value_id && !activeValues.some((v) => v.id === k.value_id)" :value="k.value_id">{{ k.value_name }} (retired)</option>
                  </select>
                </label>
                <label class="wide"><span>Message</span><input v-model="form.message" :maxlength="MESSAGE_MAX" /></label>
                <div class="form-actions">
                  <button type="button" class="button secondary small-btn" :disabled="busy" @click="cancel">Cancel</button>
                  <button type="submit" class="button small-btn" :disabled="busy">{{ busy ? 'Saving…' : 'Save' }}</button>
                </div>
              </form>
              <div v-else class="kudos-row" data-testid="kudos-admin-row">
                <div class="row-text">
                  <strong>{{ k.from_name }} → {{ k.to_name }} <span v-if="k.value_name" class="value-pill">{{ k.value_name }}</span></strong>
                  <p class="msg">{{ k.message }}</p>
                  <small>{{ shortDate(k.created_at.slice(0, 10)) }}<template v-if="k.posted_by_name"> · recorded by {{ k.posted_by_name }}</template></small>
                </div>
                <div class="actions">
                  <button class="linkish" type="button" :disabled="busy" @click="startEdit(k)">Edit</button>
                  <button class="linkish danger" type="button" :disabled="busy" @click="remove(k)">Remove</button>
                </div>
              </div>
            </template>
          </template>
        </div>
      </div>

      <div class="col">
        <KudosValuesPanel :values="overview.values" :can-edit="auth.isAdmin" @changed="loadOverview" />
      </div>
    </div>
  </section>
</template>

<style scoped>
.page { display: grid; gap: 16px; }
.page-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; flex-wrap: wrap; }
.page-sub { margin: 4px 0 0; font-size: 12px; color: var(--muted); max-width: 620px; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.grid { display: grid; grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); gap: 16px; align-items: start; }
.col { display: grid; gap: 16px; }
.card-head select { border: 1px solid #dce3d7; padding: 7px 10px; font-size: 11px; background: #fff; border-radius: 7px; }
.form { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px 14px; padding: 14px 24px 16px; }
.form.edit { background: #fafbf8; border-top: 1px solid #edf0eb; }
.form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); min-width: 0; }
.form label.wide { grid-column: 1 / -1; }
.form .form-actions { grid-column: 1 / -1; display: flex; justify-content: flex-end; gap: 8px; }
.form input, .form select { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; min-width: 0; }
.kudos-row { display: flex; align-items: flex-start; gap: 13px; padding: 12px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.row-text { flex: 1; min-width: 220px; }
.row-text strong { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 12px; font-weight: 550; }
.row-text .msg { margin: 4px 0; font-size: 13px; }
.row-text small { font-size: 11px; color: var(--muted); }
.value-pill { font-size: 10.5px; font-weight: 600; padding: 2px 8px; border-radius: 999px; background: #e8f1ea; color: #2f5d3f; }
.actions { display: flex; gap: 10px; }
.linkish.danger { color: var(--red); }
.small-btn { font-size: 11px; padding: 7px 11px; }
@media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
@media (max-width: 640px) { .form { grid-template-columns: 1fr 1fr; } }
</style>
