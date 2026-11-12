<script setup lang="ts">
import { BOARD_COLUMNS } from '@/lib/pipelineBoard'
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import {
  EMAIL_KINDS,
  PLACEHOLDERS,
  SETTINGS,
  previewTemplate,
  reasonKey,
  settingProblem,
  templateProblem,
  type EmailKind,
  type SettingKey,
} from '@/lib/hiringSettings'

/**
 * Hiring settings (0109, 0110; spec 9.13). "All companies" edits the holding
 * defaults (admins); a company's own values override them (admins and people
 * who manage that company's access). Reason codes are holding-wide.
 */
const auth = useAuthStore()
const companies = ref<{ id: string; name: string }[]>([])
const scope = ref('') // '' = all companies
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const busy = ref(false)

const scopes = computed(() => [
  ...(auth.isAdmin ? [{ id: '', name: 'All companies (defaults)' }] : []),
  ...companies.value,
])

// ------------------------------------------------------------ time limits
const values = ref<Record<SettingKey, string>>({} as Record<SettingKey, string>)
async function loadSettings(): Promise<void> {
  const query = supabase.from('hiring_settings').select('key, value')
  const { data, error: err } = scope.value ? await query.eq('company_id', scope.value) : await query.is('company_id', null)
  if (err) {
    error.value = 'Could not load the time limits.'
    return
  }
  const got = Object.fromEntries((data ?? []).map((r) => [r.key, String(r.value)]))
  values.value = Object.fromEntries(SETTINGS.map((s) => [s.key, got[s.key] ?? ''])) as Record<SettingKey, string>
}
async function saveSettings(): Promise<void> {
  const bad = SETTINGS.map((s) => settingProblem(values.value[s.key] ?? '')).find(Boolean)
  if (bad) {
    error.value = bad
    return
  }
  await run(async () => {
    const companyId = scope.value || null
    const del = companyId
      ? await supabase.from('hiring_settings').delete().eq('company_id', companyId)
      : await supabase.from('hiring_settings').delete().is('company_id', null)
    if (del.error) return del.error.message
    const rows = SETTINGS.filter((s) => (values.value[s.key] ?? '').trim()).map((s) => ({
      company_id: companyId,
      key: s.key,
      value: Number(values.value[s.key]),
    }))
    if (!rows.length) return null
    const ins = await supabase.from('hiring_settings').insert(rows)
    return ins.error?.message ?? null
  }, 'Time limits saved. Blank fields use the default.')
}

// --------------------------------------------------------- email wording
const emailKind = ref<EmailKind>('received')
const subject = ref('')
const body = ref('')
const hasTemplate = ref(false)
async function loadTemplate(): Promise<void> {
  const query = supabase.from('email_templates').select('subject, body').eq('kind', emailKind.value)
  const { data } = scope.value ? await query.eq('company_id', scope.value).maybeSingle() : await query.is('company_id', null).maybeSingle()
  hasTemplate.value = Boolean(data)
  subject.value = data?.subject ?? ''
  body.value = data?.body ?? ''
}
async function saveTemplate(): Promise<void> {
  const bad = templateProblem(subject.value, body.value)
  if (bad) {
    error.value = bad
    return
  }
  await run(async () => {
    const companyId = scope.value || null
    const del = companyId
      ? await supabase.from('email_templates').delete().eq('company_id', companyId).eq('kind', emailKind.value)
      : await supabase.from('email_templates').delete().is('company_id', null).eq('kind', emailKind.value)
    if (del.error) return del.error.message
    const ins = await supabase.from('email_templates').insert({ company_id: companyId, kind: emailKind.value, subject: subject.value.trim(), body: body.value.trim() })
    return ins.error?.message ?? null
  }, 'Email wording saved. It is used from the next email on.')
  await loadTemplate()
}
async function resetTemplate(): Promise<void> {
  await run(async () => {
    const del = scope.value
      ? await supabase.from('email_templates').delete().eq('company_id', scope.value).eq('kind', emailKind.value)
      : await supabase.from('email_templates').delete().is('company_id', null).eq('kind', emailKind.value)
    return del.error?.message ?? null
  }, 'Back to the built-in wording.')
  await loadTemplate()
}

// ----------------------------------------------------- reasons and templates
// A pipeline template names stages by status key; show the board's stage name.
const stageLabel = (key: string): string => BOARD_COLUMNS.find((c) => c.optional === key)?.label ?? key
const reasons = ref<{ key: string; label: string; archived_at: string | null }[]>([])
const newReason = ref('')
const pipelines = ref<{ id: string; name: string; skip_statuses: string[]; company_id: string | null }[]>([])
const offerTemplates = ref<{ id: string; name: string; bonus: string | null; benefits: string | null; conditions: string | null; company_id: string | null }[]>([])
const newOffer = ref({ name: '', bonus: '', benefits: '', conditions: '' })

async function loadLists(): Promise<void> {
  const [r, p, o] = await Promise.all([
    supabase.from('rejection_reasons').select('key, label, archived_at').order('sort_order'),
    supabase.from('pipeline_templates').select('id, name, skip_statuses, company_id').order('name'),
    supabase.from('offer_templates').select('id, name, bonus, benefits, conditions, company_id').order('name'),
  ])
  reasons.value = r.data ?? []
  pipelines.value = p.data ?? []
  offerTemplates.value = o.data ?? []
}
async function addReason(): Promise<void> {
  const label = newReason.value.trim()
  const key = reasonKey(label)
  if (!label || key.length < 2) {
    error.value = 'Name the reason.'
    return
  }
  await run(async () => {
    const res = await supabase.from('rejection_reasons').insert({ key, label, sort_order: 80 })
    return res.error?.message ?? null
  }, 'Reason added.')
  newReason.value = ''
  await loadLists()
}
async function toggleReason(r: { key: string; archived_at: string | null }): Promise<void> {
  await run(async () => {
    const res = await supabase.from('rejection_reasons').update({ archived_at: r.archived_at ? null : new Date().toISOString() }).eq('key', r.key)
    return res.error?.message ?? null
  }, r.archived_at ? 'Reason restored.' : 'Reason retired — kept on past rejections.')
  await loadLists()
}
async function addOfferTemplate(): Promise<void> {
  const t = newOffer.value
  if (!t.name.trim()) {
    error.value = 'Name the offer template.'
    return
  }
  await run(async () => {
    const res = await supabase.from('offer_templates').insert({
      company_id: scope.value || null,
      name: t.name.trim(),
      bonus: t.bonus.trim() || null,
      benefits: t.benefits.trim() || null,
      conditions: t.conditions.trim() || null,
    })
    return res.error?.message ?? null
  }, 'Offer template added.')
  newOffer.value = { name: '', bonus: '', benefits: '', conditions: '' }
  await loadLists()
}
async function removeOfferTemplate(id: string): Promise<void> {
  await run(async () => (await supabase.from('offer_templates').delete().eq('id', id)).error?.message ?? null, 'Offer template removed.')
  await loadLists()
}

async function run(act: () => Promise<string | null>, done: string): Promise<void> {
  busy.value = true
  error.value = null
  notice.value = null
  const problem = await act()
  busy.value = false
  if (problem) {
    console.error('Hiring settings save failed:', problem)
    error.value = /row-level security/.test(problem) ? 'You can change these only where you manage access (all companies: admins).' : problem
    return
  }
  notice.value = done
}

watch(scope, () => {
  void loadSettings()
  void loadTemplate()
})
watch(emailKind, () => void loadTemplate())
onMounted(async () => {
  const { data } = await supabase.from('companies').select('id, name').is('archived_at', null).order('name')
  companies.value = (data ?? []).filter((c) => auth.isAdmin || auth.can(c.id, 'access.manage'))
  scope.value = scopes.value[0]?.id ?? ''
  await Promise.all([loadSettings(), loadTemplate(), loadLists()])
})
</script>

<template>
  <div class="settings">
    <div class="scope">
      <label for="settings-scope">Settings for</label>
      <select id="settings-scope" v-model="scope">
        <option v-for="s in scopes" :key="s.id" :value="s.id">{{ s.name }}</option>
      </select>
    </div>
    <p v-if="notice" class="notice" role="status">{{ notice }}</p>
    <p v-if="error" class="error" role="alert">{{ error }}</p>

    <section class="card">
      <h2>Time limits</h2>
      <p class="hint">Blank uses the {{ scope ? 'holding default' : 'built-in default' }}.</p>
      <div class="grid">
        <template v-for="s in SETTINGS" :key="s.key">
          <label :for="`setting-${s.key}`">{{ s.label }}</label>
          <div class="value">
            <input :id="`setting-${s.key}`" v-model="values[s.key]" inputmode="numeric" :placeholder="String(s.fallback)" />
            <span>{{ s.unit }}</span>
          </div>
        </template>
      </div>
      <button class="button small-btn" type="button" :disabled="busy" @click="saveSettings">Save time limits</button>
    </section>

    <section class="card">
      <h2>Candidate emails</h2>
      <p class="hint">Plain text; a blank line starts a new paragraph. Placeholders: {{ PLACEHOLDERS.join(' ') }}.</p>
      <div class="row">
        <label for="email-kind">Email</label>
        <select id="email-kind" v-model="emailKind">
          <option v-for="k in EMAIL_KINDS" :key="k.kind" :value="k.kind">{{ k.label }}</option>
        </select>
        <small>{{ hasTemplate ? 'Custom wording in use' : 'Built-in wording in use' }}</small>
      </div>
      <input id="email-subject" v-model="subject" maxlength="200" placeholder="Subject" aria-label="Subject" />
      <textarea id="email-body" v-model="body" rows="7" maxlength="8000" placeholder="Dear {candidate}, …" aria-label="Email text"></textarea>
      <details v-if="subject || body">
        <summary>Preview with sample values</summary>
        <p><strong>{{ previewTemplate(subject) }}</strong></p>
        <p class="preview">{{ previewTemplate(body) }}</p>
      </details>
      <div class="row">
        <button class="button small-btn" type="button" :disabled="busy" @click="saveTemplate">Save wording</button>
        <button v-if="hasTemplate" class="button secondary small-btn" type="button" :disabled="busy" @click="resetTemplate">Use the built-in wording</button>
      </div>
    </section>

    <section v-if="auth.isAdmin" class="card">
      <h2>Rejection reasons</h2>
      <p class="hint">Every rejection records one of these. Holding-wide.</p>
      <ul class="list">
        <li v-for="r in reasons" :key="r.key" :class="{ retired: r.archived_at }">
          <span>{{ r.label }}</span>
          <button class="button secondary small-btn" type="button" :disabled="busy" @click="toggleReason(r)">{{ r.archived_at ? 'Restore' : 'Retire' }}</button>
        </li>
      </ul>
      <form class="row" @submit.prevent="addReason">
        <input id="new-reason" v-model="newReason" maxlength="80" placeholder="New reason" aria-label="New reason" />
        <button class="button small-btn" type="submit" :disabled="busy">Add</button>
      </form>
    </section>

    <section class="card">
      <h2>Offer templates</h2>
      <p class="hint">Picked when drafting an offer; the recruiter can still change every line.</p>
      <ul class="list">
        <li v-for="t in offerTemplates" :key="t.id">
          <span><strong>{{ t.name }}</strong><template v-if="!t.company_id"> · all companies</template><br /><small>{{ [t.bonus, t.benefits, t.conditions].filter(Boolean).join(' · ') }}</small></span>
          <button class="button secondary small-btn danger-text" type="button" :disabled="busy" @click="removeOfferTemplate(t.id)">Remove</button>
        </li>
      </ul>
      <form class="stack" @submit.prevent="addOfferTemplate">
        <input id="offer-tpl-name" v-model="newOffer.name" maxlength="80" placeholder="Template name" aria-label="Template name" />
        <input id="offer-tpl-bonus" v-model="newOffer.bonus" maxlength="300" placeholder="Bonus (optional)" aria-label="Bonus" />
        <textarea id="offer-tpl-benefits" v-model="newOffer.benefits" rows="2" maxlength="2000" placeholder="Benefits" aria-label="Benefits"></textarea>
        <textarea id="offer-tpl-conditions" v-model="newOffer.conditions" rows="2" maxlength="2000" placeholder="Conditions" aria-label="Conditions"></textarea>
        <button class="button small-btn" type="submit" :disabled="busy">Add offer template</button>
      </form>
    </section>

    <section class="card">
      <h2>Pipeline templates</h2>
      <p class="hint">Picked on a job's Board before it opens.</p>
      <ul class="list">
        <li v-for="p in pipelines" :key="p.id">
          <span>{{ p.name }}</span>
          <small>{{ p.skip_statuses.length ? `skips ${p.skip_statuses.map(stageLabel).join(', ')}` : 'every stage' }}</small>
        </li>
      </ul>
    </section>
  </div>
</template>

<style scoped>
.settings { display: grid; gap: 16px; }
.settings .card { display: grid; gap: 10px; padding: 20px 24px; }
.settings .card > button { justify-self: start; }
.settings h2 { margin: 0; }
.scope, .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.hint { margin: 0; color: var(--muted); font-size: 12px; }
.grid { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 6px 12px; align-items: center; }
.value { display: flex; gap: 6px; align-items: center; }
.value input { width: 80px; }
.list { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.list li { display: flex; justify-content: space-between; gap: 8px; align-items: center; flex-wrap: wrap; }
.list small { color: var(--muted); }
.retired span { text-decoration: line-through; color: var(--muted); }
.stack { display: grid; gap: 6px; }
textarea, input { min-width: 0; }
.preview { white-space: pre-line; color: var(--muted); }
.notice, .error { margin: 0; }
.error { color: var(--red, #b42318); }
@media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
</style>
