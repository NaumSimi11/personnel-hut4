<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { canIssue, labelFor, renderTemplate } from '@shared/contractTemplate'

/**
 * Issuing a contract to one person, from a published template.
 *
 * The preview is shown before the button does anything, because the refusal is
 * the useful part: a contract is not the place to discover that this person has
 * no start date recorded. What cannot be issued says so, and names what is
 * missing, so somebody can go and fill it in rather than guess.
 *
 * What comes out is a PDF filed under the person's documents. It is printed,
 * signed by hand, and the scan comes back through the ordinary upload as a new
 * version — these are employment contracts, and the app's own signature is not
 * enough for one.
 */
const props = defineProps<{ personId: string; companies: { id: string; name: string }[] }>()

type Template = { id: string; title: string; body: string; version: number; company_id: string | null }

const auth = useAuthStore()
const templates = ref<Template[]>([])
const chosen = ref('')
const values = ref<Record<string, string>>({})
const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const issued = ref<{ title: string; version: number } | null>(null)

const mayIssue = computed(() => props.companies.some((c) => auth.can(c.id, 'employment.edit')) || auth.isAdmin)
const template = computed(() => templates.value.find((t) => t.id === chosen.value) ?? null)
const rendered = computed(() => (template.value ? renderTemplate(template.value.body, values.value) : null))
const ready = computed(() => rendered.value !== null && canIssue(rendered.value))

async function load(): Promise<void> {
  loading.value = true
  const [tplRes, valRes] = await Promise.all([
    supabase
      .from('contract_templates')
      .select('id, title, body, version, company_id')
      .eq('status', 'published')
      .order('title'),
    supabase.rpc('contract_values', { p_person_id: props.personId }),
  ])
  loading.value = false
  // Only templates for a company this person belongs to, plus the holding's.
  const ids = new Set(props.companies.map((c) => c.id))
  templates.value = ((tplRes.data ?? []) as Template[]).filter(
    (t) => t.company_id === null || ids.has(t.company_id),
  )
  values.value = valRes.error ? {} : ((valRes.data ?? {}) as Record<string, string>)
  if (valRes.error) console.error('Contract values failed:', valRes.error.message)
}

watch(() => props.personId, load)

async function issue(): Promise<void> {
  if (!template.value || !ready.value) return
  busy.value = true
  error.value = null
  issued.value = null
  const { data: session } = await supabase.auth.getSession()
  const token = session.session?.access_token
  const res = await fetch('/api/contracts/issue', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
    body: JSON.stringify({ templateId: template.value.id, personId: props.personId }),
  })
  busy.value = false
  const body = await res.json().catch(() => ({}))
  if (!res.ok) {
    error.value = body.missing?.length
      ? `${body.error} Missing: ${body.missing.join(', ')}.`
      : (body.error ?? 'Could not issue the contract.')
    return
  }
  issued.value = { title: body.title, version: body.version }
}

onMounted(load)
</script>

<template>
  <div v-if="mayIssue" class="card">
    <div class="card-head">
      <div>
        <h2>Issue a contract</h2>
        <p>Filled in from this person's record, printed, signed by hand, then uploaded back.</p>
      </div>
    </div>

    <div v-if="loading" class="empty">Loading…</div>
    <div v-else-if="!templates.length" class="empty">
      No published templates for this company yet. Write one under the company's Documents tab.
    </div>

    <div v-else class="body">
      <label>
        <span>Template</span>
        <select v-model="chosen">
          <option value="">Choose one…</option>
          <option v-for="t in templates" :key="t.id" :value="t.id">{{ t.title }} (v{{ t.version }})</option>
        </select>
      </label>

      <template v-if="rendered">
        <p v-if="rendered.missing.length" class="warn">
          Cannot be issued: this person has no {{ rendered.missing.map(labelFor).join(', ') }}.
          Fill that in on their record first.
        </p>
        <p v-else-if="rendered.unknown.length" class="warn">
          The template refers to {{ rendered.unknown.join(', ') }}, which is not a field. Fix the template.
        </p>
        <pre class="preview">{{ rendered.text }}</pre>
      </template>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <p v-if="issued" class="inline-note">
        {{ issued.title }} (v{{ issued.version }}) is filed under this person's documents. Print it, sign it,
        and upload the signed copy as a new version.
      </p>

      <div class="actions">
        <button class="button small-btn" type="button" :disabled="!ready || busy" @click="issue">
          {{ busy ? 'Making it…' : 'Issue and file' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.body { display: grid; gap: 12px; padding: 16px 24px; }
label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); max-width: 420px; }
select { font: inherit; font-size: 12px; padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; background: #fff; }
.preview { margin: 0; padding: 14px; background: #fff; border: 1px solid var(--line); border-radius: 9px; font-size: 11px; line-height: 1.65; white-space: pre-wrap; max-height: 360px; overflow: auto; font-family: inherit; }
.warn { margin: 0; font-size: 11px; color: #a8332b; }
.actions { display: flex; justify-content: flex-end; }
</style>
