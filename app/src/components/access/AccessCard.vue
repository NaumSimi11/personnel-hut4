<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useDialogStore } from '@/stores/dialogs'
import { shortDate } from '@/lib/leave'
import { accessSummary, friendlyAccessError, orderAccess, type AccessRow } from '@/lib/access'

/**
 * What this person has been given, and what is still open (plan 061).
 *
 * The same card on both checklists, reading differently because the question
 * does. On the way in it is a list you add to. On the way out it is the list
 * of things still open — the one nobody could produce before, which is the
 * whole reason somebody leaves and their mailbox does not.
 *
 * Nothing here provisions anything: it is the memory of who has what, kept by
 * IT or by the person's own manager.
 */
const props = defineProps<{
  personId: string
  companyId: string
  kind: 'onboarding' | 'offboarding'
}>()
const emit = defineEmits<{ changed: [] }>()

const dialogs = useDialogStore()

const rows = ref<AccessRow[]>([])
const systems = ref<{ key: string; label: string; note: string | null }[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const busy = ref<string | null>(null)
const adding = ref(false)
const newSystem = ref('')
const newAccount = ref('')
const newNote = ref('')

/**
 * Whether this viewer may keep the list — asked of the database, not guessed.
 * The rule includes being the manager named on the person's employment, which
 * the browser has no way of knowing; `my_access_rights` answers with the same
 * helpers the writes use, so the buttons and the refusals always agree.
 */
const mayManage = ref(false)

const live = computed(() => orderAccess(rows.value.filter((r) => r.status === 'granted')))
const gone = computed(() => orderAccess(rows.value.filter((r) => r.status === 'revoked')))
const summary = computed(() => accessSummary(rows.value, props.kind))
/** Systems not already held; a second live grant is refused anyway. */
const available = computed(() => systems.value.filter((s) => !live.value.some((r) => r.system_key === s.key)))

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [rowsRes, systemsRes, rightsRes] = await Promise.all([
    supabase
      .from('person_access')
      .select(
        `id, system_key, account, status, note, granted_at, revoked_at,
         revoked_note, system:access_systems(label), granter:people!person_access_granted_by_fkey(full_name),
         revoker:people!person_access_revoked_by_fkey(full_name)`,
      )
      .eq('person_id', props.personId)
      .eq('company_id', props.companyId),
    supabase.from('access_systems').select('key, label, note').is('archived_at', null).order('sort_order'),
    supabase.rpc('my_access_rights', { p_person_id: props.personId, p_company_id: props.companyId }),
  ])
  loading.value = false
  if (rowsRes.error) {
    error.value = 'Could not load what this person has been given.'
    console.error('Access load failed:', rowsRes.error.message)
    return
  }
  rows.value = (rowsRes.data ?? []) as unknown as AccessRow[]
  if (systemsRes.error) console.error('Access systems load failed:', systemsRes.error.message)
  else systems.value = systemsRes.data ?? []
  if (rightsRes.error) console.error('Access rights load failed:', rightsRes.error.message)
  else mayManage.value = ((rightsRes.data ?? {}) as { may_manage?: boolean }).may_manage === true
}

async function add(): Promise<void> {
  if (!newSystem.value) {
    error.value = 'Pick a system first.'
    return
  }
  error.value = null
  busy.value = 'new'
  const { error: err } = await supabase.rpc('grant_access', {
    p: {
      person_id: props.personId,
      company_id: props.companyId,
      system_key: newSystem.value,
      account: newAccount.value || null,
      note: newNote.value || null,
    } as never,
  })
  busy.value = null
  if (err) {
    error.value = friendlyAccessError(err.message)
    return
  }
  newSystem.value = ''
  newAccount.value = ''
  newNote.value = ''
  adding.value = false
  await load()
  emit('changed')
}

async function revoke(row: AccessRow): Promise<void> {
  const ok = await dialogs.confirmAction({
    title: `Shut down ${row.system?.label ?? 'this access'}?`,
    hint: 'The record stays, marked as removed and dated, so the list still says what they had.',
    confirmLabel: 'Mark as shut down',
    danger: true,
  })
  if (!ok) return
  error.value = null
  busy.value = row.id
  const { error: err } = await supabase.rpc('revoke_access', { p_id: row.id })
  busy.value = null
  if (err) {
    error.value = friendlyAccessError(err.message)
    return
  }
  await load()
  emit('changed')
}

onMounted(load)
</script>

<template>
  <div class="card" data-testid="access-card">
    <div class="card-head">
      <div>
        <h2>{{ kind === 'offboarding' ? 'Access to shut down' : 'Access' }}</h2>
        <p>{{ summary }}</p>
      </div>
      <button
        v-if="mayManage && kind === 'onboarding' && !adding && available.length"
        class="button secondary small-btn"
        type="button"
        data-testid="access-add-open"
        @click="adding = true"
      >
        Record access
      </button>
    </div>

    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px" data-testid="access-error">{{ error }}</p>
    <div v-if="loading" class="empty">Loading…</div>
    <template v-else>
      <div v-if="!live.length" class="empty" data-testid="access-none">
        <template v-if="kind === 'offboarding'">
          Nothing is recorded as still open. If that looks wrong, it means nobody wrote it down — check with IT before
          ticking the line.
        </template>
        <template v-else>Nothing recorded yet.</template>
      </div>
      <ul v-else class="rows">
        <li v-for="r in live" :key="r.id" class="row" :data-testid="`access-${r.id}`">
          <div class="what">
            <strong>{{ r.system?.label ?? r.system_key }}</strong>
            <small>
              <template v-if="r.account">{{ r.account }} · </template>
              given {{ shortDate(r.granted_at.slice(0, 10)) }}<template v-if="r.granter"> by {{ r.granter.full_name }}</template>
            </small>
            <small v-if="r.note" class="note">{{ r.note }}</small>
          </div>
          <button
            v-if="mayManage"
            class="button secondary small-btn danger-text"
            type="button"
            :disabled="busy === r.id"
            :data-testid="`access-revoke-${r.id}`"
            @click="revoke(r)"
          >
            {{ kind === 'offboarding' ? 'Shut down' : 'Remove' }}
          </button>
        </li>
      </ul>

      <div v-if="adding" class="add" data-testid="access-add">
        <div class="add-fields">
          <label class="field">
            <span>System</span>
            <select v-model="newSystem" data-testid="access-system">
              <option value="">Pick one…</option>
              <option v-for="s in available" :key="s.key" :value="s.key">{{ s.label }}</option>
            </select>
          </label>
          <label class="field">
            <span>Account (optional)</span>
            <input v-model="newAccount" type="text" maxlength="200" data-testid="access-account" placeholder="username or mailbox" />
          </label>
        </div>
        <label class="field">
          <span>Note (optional)</span>
          <input v-model="newNote" type="text" maxlength="1000" data-testid="access-note" placeholder="which door, which drive, who to ask" />
        </label>
        <p class="hint">Never put a password here. This is a list of what exists, not a way in.</p>
        <div class="add-actions">
          <button class="button secondary small-btn" type="button" @click="adding = false">Cancel</button>
          <button class="button small-btn" type="button" :disabled="busy === 'new'" data-testid="access-save" @click="add">Save</button>
        </div>
      </div>

      <details v-if="gone.length" class="gone">
        <summary>{{ gone.length }} already shut down</summary>
        <ul class="rows">
          <li v-for="r in gone" :key="r.id" class="row quiet">
            <div class="what">
              <strong>{{ r.system?.label ?? r.system_key }}</strong>
              <small>
                shut down {{ r.revoked_at ? shortDate(r.revoked_at.slice(0, 10)) : '—' }}
                <template v-if="r.revoker"> by {{ r.revoker.full_name }}</template>
              </small>
            </div>
          </li>
        </ul>
      </details>
    </template>
  </div>
</template>

<style scoped>
.small-btn { font-size: 11px; padding: 7px 11px; }
.rows { list-style: none; margin: 0; padding: 0; }
.row { display: flex; gap: 12px; align-items: flex-start; padding: 12px 24px; border-top: 1px solid var(--line); }
.what { flex: 1; min-width: 0; }
.what strong { display: block; font-size: 13px; font-weight: 600; }
.what small { display: block; font-size: 11px; color: var(--muted); margin-top: 3px; line-height: 1.5; }
.what small.note { font-style: italic; }
.danger-text:not(:disabled) { color: var(--red); }
.add { padding: 14px 24px; border-top: 1px solid var(--line); background: #fbfcfa; }
.add-fields { display: grid; grid-template-columns: 1fr 1fr; gap: 0 14px; }
@media (max-width: 560px) { .add-fields { grid-template-columns: 1fr; } }
.field { display: block; margin-bottom: 10px; }
.field span { display: block; font-size: 11px; color: var(--muted); margin-bottom: 4px; }
.field select, .field input {
  width: 100%; border: 1px solid #dce3d7; border-radius: 8px; padding: 9px 11px;
  font: inherit; font-size: 12px; background: #fff; color: var(--ink);
}
.hint { font-size: 11px; color: var(--muted); margin: 0 0 10px; }
.add-actions { display: flex; gap: 8px; justify-content: flex-end; }
.gone { border-top: 1px solid var(--line); }
.gone summary { padding: 11px 24px; font-size: 11px; color: var(--muted); cursor: pointer; }
.row.quiet { padding-top: 8px; padding-bottom: 8px; }
</style>
