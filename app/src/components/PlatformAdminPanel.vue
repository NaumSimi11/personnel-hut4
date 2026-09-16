<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { platformAdminControl } from '@/lib/platformAdmin'

/**
 * Make someone a platform admin, or stop them being one — from the access
 * editor, by an admin (RLS on platform_admins). Every company, every page,
 * including inviting people and resetting passwords. A confirm step sits in
 * front of both directions; the database refuses to drop the last admin.
 */
const props = defineProps<{ personId: string; personName: string }>()

const auth = useAuthStore()
const admins = ref<{ person_id: string; granted_at: string; granted_by: string | null }[]>([])
const names = ref<Record<string, string>>({})
const loaded = ref(false)
const confirming = ref(false)
const busy = ref(false)
const error = ref<string | null>(null)
const notice = ref<string | null>(null)

const mine = computed(() => admins.value.find((a) => a.person_id === props.personId) ?? null)
const control = computed(() =>
  platformAdminControl({ isAdmin: mine.value !== null, isSelf: props.personId === auth.personId, admins: admins.value.length }),
)
const firstName = computed(() => props.personName.split(' ')[0] ?? props.personName)
const since = computed(() => (mine.value ? new Date(mine.value.granted_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : ''))
const grantedBy = computed(() => (mine.value?.granted_by ? names.value[mine.value.granted_by] ?? null : null))

async function load(): Promise<void> {
  const { data, error: err } = await supabase.from('platform_admins').select('person_id, granted_at, granted_by')
  if (err) {
    // Non-admins cannot read the list; the panel is only rendered for admins, so this is a real failure.
    error.value = 'Could not load the platform admins.'
    console.error('Platform admins load failed:', err.message)
    return
  }
  admins.value = data ?? []
  const ids = [...new Set(admins.value.flatMap((a) => [a.person_id, a.granted_by]).filter((v): v is string => !!v))]
  if (ids.length) {
    const { data: people } = await supabase.from('people').select('id, full_name').in('id', ids)
    names.value = Object.fromEntries((people ?? []).map((p) => [p.id, p.full_name]))
  }
  loaded.value = true
}

async function apply(): Promise<void> {
  error.value = null
  notice.value = null
  busy.value = true
  const { error: err } =
    control.value.action === 'grant'
      ? await supabase.from('platform_admins').insert({ person_id: props.personId, granted_by: auth.personId })
      : await supabase.from('platform_admins').delete().eq('person_id', props.personId)
  busy.value = false
  confirming.value = false
  if (err) {
    error.value = err.message.includes('row-level security') ? 'Only platform admins change who is a platform admin.' : err.message
    return
  }
  notice.value =
    control.value.action === 'grant'
      ? `${firstName.value} is a platform admin from their next sign-in: every company, every page.`
      : `${firstName.value} is no longer a platform admin. Company grants below still apply.`
  await load()
}

watch(() => props.personId, load)
onMounted(load)
</script>

<template>
  <div class="card admin-card" data-testid="platform-admin-panel">
    <div class="card-body">
      <div class="eyebrow">Holding-wide</div>
      <div class="head">
        <div>
          <h2>Platform admin</h2>
          <p v-if="!loaded" class="hint">Loading…</p>
          <p v-else-if="mine" class="status" data-testid="admin-status">
            <span class="badge green">Platform admin</span>
            since {{ since }}<template v-if="grantedBy"> · by {{ grantedBy }}</template>
          </p>
          <p v-else class="hint" data-testid="admin-status">
            Not a platform admin. Access is per company, from the grants below.
          </p>
        </div>
      </div>
      <p class="hint">
        A platform admin has every capability in every company and the pages only admins see: inviting people, resetting
        passwords, company settings, and this list. {{ admins.length }} admin{{ admins.length === 1 ? '' : 's' }} today.
      </p>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>
      <output v-if="notice" class="notice">{{ notice }}</output>

      <div v-if="loaded" class="actions">
        <template v-if="!confirming">
          <button
            class="button"
            :class="{ secondary: control.action === 'revoke' }"
            type="button"
            :disabled="control.disabled || busy"
            data-testid="admin-toggle"
            @click="confirming = true"
          >
            {{ control.label }}
          </button>
          <small v-if="control.reason" class="hint">{{ control.reason }}</small>
        </template>
        <template v-else>
          <span class="confirm-text">
            {{ control.action === 'grant' ? `Give ${firstName} full access to everything?` : `Take ${firstName}'s platform admin away?` }}
          </span>
          <button class="button" type="button" :disabled="busy" data-testid="admin-confirm" @click="apply">
            {{ busy ? 'Saving…' : 'Yes, ' + (control.action === 'grant' ? 'make admin' : 'remove') }}
          </button>
          <button class="button secondary" type="button" :disabled="busy" @click="confirming = false">Cancel</button>
        </template>
      </div>
    </div>
  </div>
</template>

<style scoped>
.admin-card { margin-bottom: 22px; }
.head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin: 4px 0 10px; }
h2 { margin: 0 0 6px; font-size: 15px; }
.status { margin: 0; font-size: 12px; color: var(--muted); display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.hint { font-size: 11px; color: var(--muted); line-height: 1.6; margin: 0 0 10px; }
.notice { display: block; padding: 10px 14px; border-radius: 9px; background: #edf5ed; color: #3e744e; font-size: 12px; margin: 0 0 12px; }
.actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.actions .hint { margin: 0; }
.confirm-text { font-size: 12px; font-weight: 600; }
</style>
