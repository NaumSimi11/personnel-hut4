<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import InviteAccessDialog from '@/components/InviteAccessDialog.vue'
import AddPersonDialog from '@/components/AddPersonDialog.vue'

type DirectoryRow = {
  id: string
  full_name: string
  work_email: string | null
  employment_periods: {
    job_title: string
    status: string
    company: { name: string } | null
  }[]
}

const auth = useAuthStore()
const rows = ref<DirectoryRow[]>([])
const query = ref('')
const loading = ref(true)
const error = ref<string | null>(null)
const inviteDialog = ref<InstanceType<typeof InviteAccessDialog> | null>(null)
const addPersonDialog = ref<InstanceType<typeof AddPersonDialog> | null>(null)

const filtered = computed(() => {
  const q = query.value.trim().toLowerCase()
  if (!q) return rows.value
  return rows.value.filter((p) =>
    [p.full_name, p.work_email ?? '', ...p.employment_periods.map((e) => `${e.job_title} ${e.company?.name ?? ''}`)]
      .join(' ')
      .toLowerCase()
      .includes(q),
  )
})

function initials(name: string): string {
  return name
    .split(' ')
    .map((part) => part[0] ?? '')
    .slice(0, 2)
    .join('')
}

function currentEmployment(p: DirectoryRow) {
  return p.employment_periods[0] ?? null
}

async function load(): Promise<void> {
  const { data, error: err } = await supabase
    .from('people')
    .select(
      'id, full_name, work_email, employment_periods!person_id(job_title, status, company:companies(name))',
    )
    .is('archived_at', null)
    .order('full_name')
  if (err) {
    error.value = 'Could not load the directory. Check your access and connection.'
    console.error('Directory load failed:', err.message)
  } else {
    rows.value = (data ?? []) as DirectoryRow[]
  }
  loading.value = false
}

onMounted(load)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">People &amp; access</div>
        <h1>The right access for every person.</h1>
      </div>
      <div v-if="auth.isAdmin" class="head-actions">
        <button class="button secondary" type="button" @click="addPersonDialog?.open()">
          Add person
        </button>
        <button class="button" type="button" @click="inviteDialog?.openInvite()">
          Invite person
        </button>
      </div>
    </div>

    <div class="card">
      <div class="card-head">
        <div>
          <h2>Employee directory</h2>
          <p>Everyone you are permitted to see, across the holding.</p>
        </div>
        <input
          v-model="query"
          class="search"
          aria-label="Search people"
          placeholder="Search name, role, company…"
        />
      </div>
      <p v-if="error" class="error-note" style="margin: 16px 24px">{{ error }}</p>
      <div v-else-if="loading" class="empty">Loading directory…</div>
      <div v-else-if="!filtered.length" class="empty">
        <template v-if="rows.length">No people match your search.</template>
        <template v-else>No people visible with your current access.</template>
      </div>
      <div v-else class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Person</th>
              <th>Company</th>
              <th>Role</th>
              <th>Status</th>
              <th>Access</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="p in filtered" :key="p.id">
              <td>
                <router-link
                  class="person-cell person-link"
                  :to="{ name: 'person', params: { personId: p.id } }"
                >
                  <span class="avatar" aria-hidden="true">{{ initials(p.full_name) }}</span>
                  <div>
                    <strong>{{ p.full_name }}</strong>
                    <small>{{ p.work_email ?? '—' }}</small>
                  </div>
                </router-link>
              </td>
              <td>{{ currentEmployment(p)?.company?.name ?? '—' }}</td>
              <td>{{ currentEmployment(p)?.job_title ?? '—' }}</td>
              <td>
                <span
                  class="badge"
                  :class="currentEmployment(p)?.status === 'active' ? 'green' : 'blue'"
                >
                  {{ currentEmployment(p)?.status ?? 'no employment' }}
                </span>
              </td>
              <td>
                <div class="row-actions">
                  <router-link
                    class="button secondary small-link"
                    :to="{ name: 'access-editor', params: { personId: p.id } }"
                  >
                    Manage access
                  </router-link>
                  <button
                    v-if="auth.isAdmin"
                    class="button secondary small-link"
                    type="button"
                    @click="inviteDialog?.openReset({ id: p.id, name: p.full_name })"
                  >
                    Reset access
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    <InviteAccessDialog ref="inviteDialog" @invited="load" />
    <AddPersonDialog ref="addPersonDialog" @created="load" />
  </div>
</template>

<style scoped>
.search {
  border: 1px solid var(--line);
  background: #fafbf9;
  padding: 9px 12px;
  font-size: 12px;
  width: 235px;
  max-width: 100%;
}
.small-link { font-size: 11px; padding: 7px 11px; text-decoration: none; }
.row-actions { display: flex; gap: 7px; flex-wrap: wrap; }
.head-actions { display: flex; gap: 9px; flex-wrap: wrap; }
.person-link { text-decoration: none; color: inherit; }
.person-link:hover strong { color: var(--green); text-decoration: underline; }
.page-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
}
h1 { margin-bottom: 24px; }
</style>
