<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { bodyEditable, friendlyHardDeleteError, policyDeletable } from '@/lib/hardDelete'
import {
  POLICY_ACCEPT,
  POLICY_BUCKET,
  createPolicy,
  friendlyPolicyError,
  policyInput,
  publishPolicy,
  replaceDraftFile,
  signedPolicyUrl,
  validatePolicyFile,
  type PolicyRow,
} from '@/lib/policies'

/**
 * Policies for one company — or holding-wide when `companyId` is null
 * (plan 028). Publishers (policies.publish; platform admins for the
 * holding) add, publish, re-publish and archive; everyone in scope reads
 * published ones. The acknowledged count is per current version.
 */

const props = defineProps<{ companyId: string | null }>()

const auth = useAuthStore()
const dialogs = useDialogStore()
const canPublish = computed(() => (props.companyId ? auth.can(props.companyId, 'policies.publish') : auth.isAdmin))

const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)
const policies = ref<PolicyRow[]>([])
const acknowledged = ref<Record<string, number>>({})
/** Agreed to at ANY version — the number `delete_policy` refuses on. */
const acknowledgedEver = ref<Record<string, number>>({})
const headcount = ref<number | null>(null)
const adding = ref(false)
const form = ref({ title: '', summary: '', body: '' })
const reading = ref<PolicyRow | null>(null)
const newText = ref<Record<string, string>>({})
/** The policy being corrected in place, and the fields as they are being typed. */
const editing = ref<string | null>(null)
const edit = ref({ title: '', summary: '', body: '' })
const fileInput = ref<HTMLInputElement | null>(null)
const fileInputs = ref<Record<string, HTMLInputElement | null>>({})

const shown = computed(() =>
  [...policies.value].sort((a, b) => Number(a.status === 'archived') - Number(b.status === 'archived') || a.title.localeCompare(b.title)),
)

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  let query = supabase.from('policies').select('*')
  query = props.companyId ? query.eq('company_id', props.companyId) : query.is('company_id', null)
  const [polRes, headRes] = await Promise.all([
    query.order('title'),
    props.companyId
      ? supabase
          .from('employment_periods')
          .select('person_id', { count: 'exact', head: true })
          .eq('company_id', props.companyId)
          .eq('status', 'active')
      : Promise.resolve({ count: null, error: null }),
  ])
  if (polRes.error) {
    error.value = 'Could not load policies.'
    console.error('Policies load failed:', polRes.error.message)
    loading.value = false
    return
  }
  policies.value = (polRes.data ?? []) as PolicyRow[]
  headcount.value = headRes.error ? null : (headRes.count ?? null)
  const ids = policies.value.map((p) => p.id)
  if (ids.length) {
    const { data } = await supabase.from('policy_acknowledgements').select('policy_id, version, person_id').in('policy_id', ids)
    const counts: Record<string, Set<string>> = {}
    const ever: Record<string, number> = {}
    for (const ack of data ?? []) {
      const policy = policies.value.find((p) => p.id === ack.policy_id)
      if (!policy) continue
      // "Ever agreed" is what decides whether a policy may be deleted (0080
      // counts every version); "agreed to THIS version" is what the count on
      // screen means. They are different numbers and both are needed.
      ever[ack.policy_id] = (ever[ack.policy_id] ?? 0) + 1
      if (ack.version !== policy.version) continue
      counts[ack.policy_id] = (counts[ack.policy_id] ?? new Set<string>()).add(ack.person_id)
    }
    acknowledged.value = Object.fromEntries(Object.entries(counts).map(([id, people]) => [id, people.size]))
    acknowledgedEver.value = ever
  } else {
    acknowledged.value = {}
    acknowledgedEver.value = {}
  }
  loading.value = false
}

function startAdd(): void {
  form.value = { title: '', summary: '', body: '' }
  error.value = null
  notice.value = null
  adding.value = true
}

async function saveDraft(): Promise<void> {
  const file = fileInput.value?.files?.[0] ?? null
  const fileProblem = file ? validatePolicyFile(file) : null
  if (fileProblem) {
    error.value = fileProblem
    return
  }
  const parsed = policyInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  if (!file && !parsed.data.body) {
    error.value = 'Write the policy here or attach its file.'
    return
  }
  busy.value = true
  error.value = null
  try {
    await createPolicy({ companyId: props.companyId, title: parsed.data.title, summary: parsed.data.summary, body: parsed.data.body, file })
    adding.value = false
    notice.value = 'Draft saved. Publish it when it is ready to be read.'
    await load()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not save the policy.'
    console.error('Policy draft failed:', error.value)
  } finally {
    busy.value = false
  }
}

/** A published text policy gets a new version from new text (a file policy from a new file, below). */
async function publishNewText(policy: PolicyRow): Promise<void> {
  const text = (newText.value[policy.id] ?? '').trim()
  if (text.length < 2) {
    error.value = 'Write the new text first.'
    return
  }
  busy.value = true
  error.value = null
  notice.value = null
  try {
    await publishPolicy(policy, null, text)
    newText.value = { ...newText.value, [policy.id]: '' }
    notice.value = 'Published as a new version. Everyone will need to acknowledge it again.'
    await load()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not publish.'
  } finally {
    busy.value = false
  }
}

async function publishDraft(policy: PolicyRow): Promise<void> {
  busy.value = true
  error.value = null
  notice.value = null
  try {
    await publishPolicy(policy, null)
    notice.value = 'Published. Everyone in scope can read it now.'
    await load()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not publish.'
    console.error('Policy publish failed:', error.value)
  } finally {
    busy.value = false
  }
}

function startEdit(policy: PolicyRow): void {
  editing.value = policy.id
  edit.value = { title: policy.title, summary: policy.summary ?? '', body: policy.body ?? '' }
  error.value = null
}

/**
 * Correct a policy in place. The title and summary are how it is referred to
 * and may be fixed whenever; the body only while it is a draft, because once
 * published it is what people agreed to and changes by version (0080).
 */
async function saveEdit(policy: PolicyRow): Promise<void> {
  error.value = null
  busy.value = true
  const payload: Record<string, string | null> = {
    title: edit.value.title,
    summary: edit.value.summary,
    ...(bodyEditable(policy) ? { body: edit.value.body } : {}),
  }
  const { error: err } = await supabase.rpc('update_policy', { p_policy_id: policy.id, p: payload as never })
  busy.value = false
  if (err) {
    error.value = friendlyHardDeleteError(err.message)
    return
  }
  editing.value = null
  notice.value = 'Saved.'
  await load()
}

/** Hard delete, for a policy that was a mistake. Archive is for the rest. */
async function remove(policy: PolicyRow): Promise<void> {
  const verdict = policyDeletable({ acknowledgements: acknowledgedEver.value[policy.id] ?? 0, status: policy.status }, canPublish.value)
  if (!verdict.canDelete) return
  const ok = await dialogs.confirmAction({
    title: `Delete "${policy.title}"?`,
    hint: 'Nobody has agreed to it, so nothing is lost. This cannot be undone — archive instead if you only want it out of the way.',
    confirmLabel: 'Delete policy',
    danger: true,
  })
  if (!ok) return
  error.value = null
  busy.value = true
  const { data, error: err } = await supabase.rpc('delete_policy', { p_policy_id: policy.id })
  if (err) {
    busy.value = false
    error.value = friendlyHardDeleteError(err.message)
    return
  }
  // The row is gone; the file it pointed at is not, and only the app can reach
  // Storage to remove it.
  const path = (data as { storage_path?: string | null } | null)?.storage_path
  if (path) {
    const { error: fileErr } = await supabase.storage.from(POLICY_BUCKET).remove([path])
    if (fileErr) console.error('Policy file not removed:', fileErr.message)
  }
  busy.value = false
  notice.value = `"${policy.title}" deleted.`
  await load()
}

async function archive(policy: PolicyRow): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Archive "${policy.title}"?`,
    hint: "It disappears from everyone's list; acknowledgements are kept.",
    confirmLabel: 'Archive',
    danger: true,
  })
  if (!ok) return
  busy.value = true
  error.value = null
  notice.value = null
  const { error: err } = await supabase.rpc('archive_policy', { p_policy_id: policy.id })
  busy.value = false
  if (err) {
    error.value = friendlyPolicyError(err.message)
    console.error('Policy archive failed:', err.message)
    return
  }
  await load()
}

/** A draft's file is replaced; a published policy's new file becomes a new version. */
async function fileChosen(policy: PolicyRow): Promise<void> {
  const input = fileInputs.value[policy.id]
  const file = input?.files?.[0]
  if (!file) return
  const fileProblem = validatePolicyFile(file)
  if (fileProblem) {
    error.value = fileProblem
    return
  }
  if (policy.status === 'published') {
    const ok = await dialogs.confirmAction({
      title: `Publish this file as version ${policy.version + 1} of "${policy.title}"?`,
      hint: 'Everyone will need to acknowledge it again.',
      confirmLabel: 'Publish new version',
    })
    if (!ok) {
      if (input) input.value = ''
      return
    }
  }
  busy.value = true
  error.value = null
  notice.value = null
  try {
    if (policy.status === 'published') {
      await publishPolicy(policy, file)
      notice.value = `Version ${policy.version + 1} published.`
    } else {
      await replaceDraftFile(policy, file)
      notice.value = 'File replaced.'
    }
    await load()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not store the file.'
    console.error('Policy file failed:', error.value)
  } finally {
    if (input) input.value = ''
    busy.value = false
  }
}

async function open(policy: PolicyRow): Promise<void> {
  if (!policy.storage_path) return
  const tab = window.open('', '_blank')
  try {
    const url = await signedPolicyUrl(policy.storage_path)
    if (tab) tab.location.href = url
  } catch (e) {
    tab?.close()
    error.value = e instanceof Error ? e.message : 'Could not open the policy.'
  }
}

function statusLabel(p: PolicyRow): string {
  if (p.status === 'published') return `Published v${p.version}`
  if (p.status === 'archived') return 'Archived'
  return 'Draft'
}

onMounted(load)
watch(() => props.companyId, load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Policies</h2>
        <p>{{ companyId ? 'Published policies are read by everyone in the company; each person acknowledges the version they read.' : 'Holding-wide policies apply to every company.' }}</p>
      </div>
      <button v-if="canPublish && !adding" class="button small-btn" type="button" @click="startAdd">Add policy</button>
    </div>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="notice" class="notice" role="status">{{ notice }}</div>
      <div v-if="error" class="error" role="alert">{{ error }}</div>

      <form v-if="adding" class="pol-form" novalidate @submit.prevent="saveDraft">
        <label>
          <span>Title</span>
          <input id="pol-title" v-model="form.title" maxlength="160" />
        </label>
        <label>
          <span>File</span>
          <input id="pol-file" ref="fileInput" type="file" :accept="POLICY_ACCEPT" />
        </label>
        <label class="wide">
          <span>Summary</span>
          <input id="pol-summary" v-model="form.summary" placeholder="One line on what it covers (optional)" />
        </label>
        <label class="wide">
          <span>Text (write it here, or attach a file above)</span>
          <textarea id="pol-body" v-model="form.body" rows="6" maxlength="20000" placeholder="The policy itself, in plain words."></textarea>
        </label>
        <div class="form-actions">
          <button type="button" class="button secondary small-btn" :disabled="busy" @click="adding = false">Cancel</button>
          <button type="submit" class="button small-btn" :disabled="busy">{{ busy ? 'Saving…' : 'Save draft' }}</button>
        </div>
      </form>

      <div v-if="!shown.length" class="empty">No policies yet.</div>
      <div v-for="p in shown" :key="p.id" class="policy-row" :class="p.status">
        <div class="row-text">
          <strong>{{ p.title }} <span class="version">{{ statusLabel(p) }}</span></strong>
          <small>
            <template v-if="p.status === 'published'">
              {{ acknowledged[p.id] ?? 0 }} acknowledged<template v-if="headcount !== null"> of {{ headcount }} active</template>
              · published {{ p.published_at?.slice(0, 10) }}
            </template>
            <template v-else-if="p.status === 'draft'">Not yet visible to people.</template>
            <template v-if="p.summary"> · {{ p.summary }}</template>
          </small>
        </div>
        <div class="actions">
          <button v-if="p.storage_path" class="button secondary small-btn" type="button" @click="open(p)">Open</button>
          <button v-else-if="p.body" class="button secondary small-btn" type="button" :data-testid="`read-${p.id}`" @click="reading = reading?.id === p.id ? null : p">{{ reading?.id === p.id ? 'Hide' : 'Read' }}</button>
          <template v-if="canPublish && p.status !== 'archived'">
            <button v-if="p.status === 'draft'" class="button small-btn" type="button" :disabled="busy" @click="publishDraft(p)">
              Publish
            </button>
            <label class="replace" :class="{ primary: p.status === 'published' }">
              <input
                :ref="(el) => (fileInputs[p.id] = el as HTMLInputElement | null)"
                type="file"
                :accept="POLICY_ACCEPT"
                :disabled="busy"
                @change="fileChosen(p)"
              />
              <span class="button small-btn" :class="{ secondary: p.status !== 'published' }">
                {{ p.status === 'published' ? 'Publish new version' : 'Replace file' }}
              </span>
            </label>
            <button class="button secondary small-btn" type="button" :disabled="busy" :data-testid="`edit-${p.id}`" @click="startEdit(p)">Edit</button>
            <button class="button secondary small-btn" type="button" :disabled="busy" @click="archive(p)">Archive</button>
            <button
              class="button secondary small-btn danger-text"
              type="button"
              :disabled="busy || !policyDeletable({ acknowledgements: acknowledgedEver[p.id] ?? 0, status: p.status }, canPublish).canDelete"
              :title="policyDeletable({ acknowledgements: acknowledgedEver[p.id] ?? 0, status: p.status }, canPublish).reason ?? 'Nobody has agreed to this one, so it can go.'"
              :data-testid="`delete-${p.id}`"
              @click="remove(p)"
            >
              Delete
            </button>
          </template>
        </div>
        <div v-if="editing === p.id" class="wide-row edit-row" :data-testid="`edit-form-${p.id}`">
          <label>
            <span>Title</span>
            <input v-model="edit.title" type="text" maxlength="200" :data-testid="`edit-title-${p.id}`" />
          </label>
          <label>
            <span>Summary — the one line that goes in the welcome note</span>
            <input v-model="edit.summary" type="text" maxlength="500" :data-testid="`edit-summary-${p.id}`" />
          </label>
          <label v-if="bodyEditable(p)">
            <span>Text</span>
            <textarea v-model="edit.body" rows="6" maxlength="20000" :data-testid="`edit-body-${p.id}`"></textarea>
          </label>
          <p v-else class="hint">
            This one is published, so its text is what people agreed to. Change it by publishing a new version below.
          </p>
          <div class="edit-actions">
            <button class="button secondary small-btn" type="button" @click="editing = null">Cancel</button>
            <button class="button small-btn" type="button" :disabled="busy" :data-testid="`edit-save-${p.id}`" @click="saveEdit(p)">Save</button>
          </div>
        </div>
        <div v-if="reading?.id === p.id && p.body" class="body-text wide-row" :data-testid="`body-${p.id}`">{{ p.body }}</div>
        <div v-if="canPublish && p.status === 'published' && !p.storage_path" class="wide-row new-text">
          <textarea v-model="newText[p.id]" rows="3" maxlength="20000" :placeholder="`New text for the next version of ${p.title}`" :aria-label="`New text for ${p.title}`"></textarea>
          <button class="button small-btn" type="button" :disabled="busy" @click="publishNewText(p)">Publish new text</button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.policy-row { display: flex; align-items: center; gap: 13px; padding: 13px 24px; border-top: 1px solid #edf0eb; flex-wrap: wrap; }
.policy-row.archived { opacity: 0.6; }
.wide-row { flex-basis: 100%; }
.body-text { white-space: pre-wrap; font-size: 12px; line-height: 1.55; padding: 10px 12px; background: #fafbf8; border: 1px solid #edf0eb; border-radius: 8px; }
.new-text { display: flex; gap: 8px; align-items: flex-start; }
.new-text textarea { flex: 1; border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; font-family: inherit; }
.pol-form textarea { width: 100%; border: 1px solid #dce3d7; padding: 8px 10px; font-size: 12px; font-family: inherit; }
.row-text { flex: 1; min-width: 200px; }
.row-text strong { display: block; font-size: 12px; font-weight: 550; }
.row-text small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.version { font-size: 11px; font-weight: 600; color: var(--muted); margin-left: 4px; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.small-btn { font-size: 11px; padding: 7px 11px; }
.replace input { position: absolute; width: 1px; height: 1px; opacity: 0.01; }
.replace span { cursor: pointer; display: inline-block; }
.pol-form { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 14px; padding: 16px 24px; background: #fafbf8; border-top: 1px solid var(--line); }
.pol-form label { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.pol-form label.wide, .pol-form .form-actions { grid-column: 1 / -1; }
.pol-form input { font: inherit; font-size: 12px; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: #fff; }
.form-actions { display: flex; justify-content: flex-end; gap: 8px; }
.notice { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; }
.error { margin: 14px 24px 0; padding: 10px 14px; border-radius: 9px; background: #fbeaea; color: var(--red); font-size: 12px; }
@media (max-width: 560px) { .pol-form { grid-template-columns: 1fr; } }
</style>
