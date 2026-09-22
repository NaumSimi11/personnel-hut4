<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { departureState } from '@/lib/departure'
import { DIRECTORY_FILTERS, currentPeriod, matchesFilter, type DirectoryFilter } from '@/lib/employmentChanges'
import { personRemovable, removalConfirmation } from '@/lib/personRemoval'
import InviteAccessDialog from '@/components/InviteAccessDialog.vue'
import AddEmployeeDialog from '@/components/AddEmployeeDialog.vue'
import ImportPeopleDialog from '@/components/ImportPeopleDialog.vue'
import CompanyFilter from '@/components/CompanyFilter.vue'
import AvatarImage from '@/components/AvatarImage.vue'

type DirectoryRow = {
  id: string
  full_name: string
  avatar_url: string | null
  work_email: string | null
  employment_periods: {
    job_title: string
    status: string
    start_date: string
    end_date: string | null
    last_working_date: string | null
    company_id: string
    company: { name: string } | null
    department: { name: string } | null
  }[]
  archived_at: string | null
}

const auth = useAuthStore()
const rows = ref<DirectoryRow[]>([])
const query = ref('')
// The directory opens on the people who work here. 'Everyone' includes those
// who left years ago, which is a question somebody asks, not the answer to open on.
const filter = ref<DirectoryFilter>('active')
const companyFilter = ref('')
const companies = ref<{ id: string; name: string }[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
// Removed people are archived, not deleted, so the directory can show them
// again and put them back (personRemoval.ts says why).
const showRemoved = ref(false)
const confirmingRemoval = ref<string | null>(null)
const removing = ref(false)

const inviteDialog = ref<InstanceType<typeof InviteAccessDialog> | null>(null)
const addEmployeeDialog = ref<InstanceType<typeof AddEmployeeDialog> | null>(null)
const importDialog = ref<InstanceType<typeof ImportPeopleDialog> | null>(null)
const canImport = computed(() => auth.isAdmin || companies.value.some((c) => auth.can(c.id, 'employment.edit')))

const filtered = computed(() => {
  const q = query.value.trim().toLowerCase()
  return rows.value.filter((p) => {
    const current = currentEmployment(p)
    if (!matchesFilter(filter.value, current)) return false
    if (companyFilter.value && current?.company_id !== companyFilter.value) return false
    if (!q) return true
    return [p.full_name, p.work_email ?? '', ...p.employment_periods.map((e) => `${e.job_title} ${e.company?.name ?? ''} ${e.department?.name ?? ''}`)]
      .join(' ')
      .toLowerCase()
      .includes(q)
  })
})

function initials(name: string): string {
  return name
    .split(' ')
    .map((part) => part[0] ?? '')
    .slice(0, 2)
    .join('')
}

function currentEmployment(p: DirectoryRow) {
  return currentPeriod(p.employment_periods)
}
const adminIds = ref<Set<string>>(new Set())

async function load(): Promise<void> {
  // Scheduled employment changes whose date has arrived apply on the way in.
  const due = await supabase.rpc('apply_due_employment_changes')
  if (due.error) console.error('Applying due employment changes failed:', due.error.message)
  const companiesRes = await supabase.from('companies').select('id, name').is('archived_at', null).order('name')
  companies.value = companiesRes.data ?? []
  if (auth.isAdmin) {
    // Who runs the platform — readable by admins only, shown as a badge so it is never a surprise.
    const adminsRes = await supabase.from('platform_admins').select('person_id')
    adminIds.value = new Set((adminsRes.data ?? []).map((a) => a.person_id))
  }
  const base = supabase
    .from('people')
    .select(
      'id, full_name, work_email, avatar_url, archived_at, employment_periods!person_id(job_title, status, start_date, end_date, last_working_date, company_id, company:companies(name), department:departments(name))',
    )
  const { data, error: err } = await (showRemoved.value
    ? base.not('archived_at', 'is', null)
    : base.is('archived_at', null)
  ).order('full_name')
  if (err) {
    error.value = 'Could not load the directory. Check your access and connection.'
    console.error('Directory load failed:', err.message)
  } else {
    rows.value = (data ?? []) as DirectoryRow[]
  }
  loading.value = false
}

function removalVerdict(p: DirectoryRow) {
  return personRemovable({ employed: currentEmployment(p) !== null, isSelf: p.id === auth.personId }, auth.isAdmin)
}

async function setArchived(p: DirectoryRow, archived: boolean): Promise<void> {
  error.value = null
  removing.value = true
  const { error: err } = await supabase
    .from('people')
    .update({ archived_at: archived ? new Date().toISOString() : null })
    .eq('id', p.id)
  removing.value = false
  confirmingRemoval.value = null
  if (err) {
    error.value = err.message.includes('row-level security')
      ? 'Only platform admins remove people from the directory.'
      : err.message
    return
  }
  await load()
}

watch(showRemoved, () => {
  confirmingRemoval.value = null
  void load()
})

onMounted(load)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">People &amp; access</div>
        <h1>The right access for every person.</h1>
      </div>
      <div v-if="auth.isAdmin || canImport" class="head-actions">
        <button v-if="canImport" class="button secondary" type="button" @click="importDialog?.open()">
          Import people
        </button>
        <button v-if="canImport" class="button secondary" type="button" data-testid="add-employee" @click="addEmployeeDialog?.open()">
          Add employee
        </button>
        <button v-if="auth.isAdmin" class="button" type="button" @click="inviteDialog?.openInvite()">
          Invite person
        </button>
      </div>
    </div>

    <div class="card">
      <div class="card-head">
        <div>
          <h2>Employee directory</h2>
          <p>The people you are permitted to see, across the holding.</p>
        </div>
        <input
          v-model="query"
          class="search"
          aria-label="Search people"
          placeholder="Search name, role, company…"
        />
      </div>
      <div class="filters">
        <div class="chips" role="group" aria-label="Employment state">
          <button
            v-for="f in DIRECTORY_FILTERS"
            :key="f.key"
            class="chip"
            :class="{ active: filter === f.key }"
            type="button"
            :aria-pressed="filter === f.key"
            @click="filter = f.key"
          >
            {{ f.label }}
          </button>
        </div>
        <div class="filter-right">
          <label v-if="auth.isAdmin" class="removed-toggle">
            <input v-model="showRemoved" type="checkbox" data-testid="show-removed" />
            Removed people
          </label>
          <CompanyFilter v-model="companyFilter" :companies="companies" all-label="All companies" />
        </div>
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
                  <AvatarImage :name="p.full_name" :path="p.avatar_url" />
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
                <span
                  v-if="currentEmployment(p) && departureState(currentEmployment(p)!) === 'departing'"
                  class="badge amber departing-badge"
                  :title="`Last day ${currentEmployment(p)!.last_working_date ?? currentEmployment(p)!.end_date}`"
                >
                  Departing
                </span>
                <span v-if="adminIds.has(p.id)" class="badge departing-badge" title="Platform admin: every company, every page" data-testid="admin-badge">
                  Admin
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
                  <template v-if="confirmingRemoval === p.id">
                    <span class="confirm-text">{{ removalConfirmation(p.full_name) }}</span>
                    <button class="button small-link" type="button" :disabled="removing" @click="setArchived(p, true)">
                      {{ removing ? 'Removing…' : 'Yes, remove' }}
                    </button>
                    <button class="button secondary small-link" type="button" :disabled="removing" @click="confirmingRemoval = null">
                      Cancel
                    </button>
                  </template>
                  <button
                    v-else-if="p.archived_at"
                    class="button secondary small-link"
                    type="button"
                    :disabled="removing || !auth.isAdmin"
                    :data-testid="`restore-person-${p.id}`"
                    @click="setArchived(p, false)"
                  >
                    {{ removing ? 'Restoring…' : 'Restore' }}
                  </button>
                  <button
                    v-else-if="auth.isAdmin"
                    class="button secondary small-link"
                    type="button"
                    :disabled="!removalVerdict(p).canRemove"
                    :title="removalVerdict(p).reason ?? 'Remove from the directory'"
                    :data-testid="`remove-person-${p.id}`"
                    @click="confirmingRemoval = p.id"
                  >
                    Remove
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    <InviteAccessDialog ref="inviteDialog" @invited="load" />
    <AddEmployeeDialog ref="addEmployeeDialog" @created="load" />
    <ImportPeopleDialog ref="importDialog" :companies="companies" @imported="load" />
  </div>
</template>

<style scoped>
.departing-badge { margin-left: 6px; }
.filters { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding: 12px 24px; border-bottom: 1px solid var(--line); background: #fafbf9; }
.chips { display: flex; gap: 6px; flex-wrap: wrap; }
.chip { border: 1px solid var(--line); background: #fff; color: var(--muted); font-size: 11px; padding: 6px 11px; border-radius: 999px; }
.chip.active { background: var(--green); border-color: var(--green); color: #fff; }
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
.filter-right { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
.removed-toggle { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
.confirm-text { font-size: 11px; font-weight: 600; }
</style>
