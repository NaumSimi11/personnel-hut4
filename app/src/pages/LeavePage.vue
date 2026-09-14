<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { EMPLOYED_STATUSES } from '@/lib/leave'
import LeaveCalendarPanel from '@/components/leave/LeaveCalendarPanel.vue'
import LeaveRequestsPanel from '@/components/leave/LeaveRequestsPanel.vue'
import LeaveBalancesPanel from '@/components/leave/LeaveBalancesPanel.vue'
import HolidaysPanel from '@/components/leave/HolidaysPanel.vue'
import CompanyFilter from '@/components/CompanyFilter.vue'

/**
 * Leave (plan 036): Calendar · Requests · Balances · Holidays, driven by
 * ?tab= and ?company=. The viewer's companies are the ones they are
 * employed in or hold a leave grant for (admins: all). Every number and
 * every write comes from migration 0027's functions.
 */

type TabId = 'calendar' | 'requests' | 'balances' | 'holidays'
type Company = { id: string; name: string; country_code: string | null; leave_entitlement_days: number }

const TABS: { id: TabId; label: string }[] = [
  { id: 'calendar', label: 'Calendar' },
  { id: 'requests', label: 'Requests' },
  { id: 'balances', label: 'Balances' },
  { id: 'holidays', label: 'Holidays' },
]

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const companies = ref<Company[]>([])
const ALL = ''
const companyId = ref(ALL)
const loading = ref(true)
const error = ref<string | null>(null)

const activeTab = computed<TabId>(() => {
  const raw = route.query.tab
  return TABS.some((t) => t.id === raw) ? (raw as TabId) : 'calendar'
})
/** The companies the panels show: one, or every company the viewer may see. */
const selected = computed(() => (companyId.value === ALL ? companies.value : companies.value.filter((c) => c.id === companyId.value)))
const approverCompanies = computed(() => companies.value.filter((c) => auth.can(c.id, 'leave.view') || auth.can(c.id, 'leave.approve')))
const canSeeBalances = computed(() => companies.value.some((c) => auth.can(c.id, 'leave.view')))
const visibleTabs = computed(() =>
  TABS.filter((t) => (t.id === 'requests' ? approverCompanies.value.length > 0 : t.id === 'balances' ? canSeeBalances.value : true)),
)
const balanceCompanies = computed(() => selected.value.filter((c) => auth.can(c.id, 'leave.view')))

function selectTab(id: TabId): void {
  router.replace({ query: { ...route.query, tab: id } })
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [companiesRes, mineRes] = await Promise.all([
    supabase.from('companies').select('id, name, country_code, leave_entitlement_days').is('archived_at', null).order('name'),
    auth.personId
      ? supabase.from('employment_periods').select('company_id').eq('person_id', auth.personId).in('status', EMPLOYED_STATUSES)
      : Promise.resolve({ data: [] as { company_id: string }[], error: null }),
  ])
  if (companiesRes.error) {
    error.value = 'Could not load companies.'
    console.error('Leave page load failed:', companiesRes.error.message)
    loading.value = false
    return
  }
  const mine = new Set((mineRes.data ?? []).map((e) => e.company_id))
  companies.value = (companiesRes.data ?? []).filter(
    (c) => auth.isAdmin || mine.has(c.id) || auth.can(c.id, 'leave.view') || auth.can(c.id, 'leave.approve'),
  )
  const wanted = typeof route.query.company === 'string' ? route.query.company : ''
  companyId.value = companies.value.some((c) => c.id === wanted) ? wanted : companies.value.length > 1 ? ALL : (companies.value[0]?.id ?? ALL)
  loading.value = false
}

watch(companyId, (id) => {
  if ((route.query.company ?? '') !== id) router.replace({ query: { ...route.query, company: id || undefined } })
})
onMounted(load)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">Leave</div>
        <h1>Who is away, and what is left.</h1>
        <p class="page-sub">Requests go to whoever approves leave in the company; balances follow the employment.</p>
      </div>
    </div>

    <p v-if="error" class="error-note" role="alert">{{ error }}</p>
    <div v-else-if="loading" class="empty">Loading…</div>
    <div v-else-if="!companies.length" class="empty">You are not employed in any company yet, so there is no leave to show.</div>
    <template v-else>
      <div class="tabs-row">
        <div class="tabs" role="tablist" aria-label="Leave">
          <button
            v-for="tab in visibleTabs"
            :key="tab.id"
            class="tab"
            :class="{ active: activeTab === tab.id }"
            type="button"
            role="tab"
            :aria-selected="activeTab === tab.id"
            @click="selectTab(tab.id)"
          >
            {{ tab.label }}
          </button>
        </div>
        <CompanyFilter
          v-if="companies.length > 1 && activeTab !== 'holidays' && activeTab !== 'requests'"
          id="leave-company"
          v-model="companyId"
          :companies="companies"
          all-label="All companies"
        />
      </div>
      <LeaveCalendarPanel v-if="activeTab === 'calendar'" :companies="selected" />
      <LeaveRequestsPanel v-else-if="activeTab === 'requests'" :company-ids="approverCompanies.map((c) => c.id)" />
      <template v-else-if="activeTab === 'balances'">
        <LeaveBalancesPanel v-if="balanceCompanies.length" :companies="balanceCompanies" />
        <div v-else class="empty">Balances need leave.view in the selected company.</div>
      </template>
      <HolidaysPanel v-else-if="activeTab === 'holidays'" :companies="companies" />
    </template>
  </div>
</template>

<style scoped>
.page-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 24px; }
.page-sub { margin: 0; font-size: 12px; color: var(--muted); max-width: 560px; }
.tabs-row { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; border-bottom: 1px solid var(--line); margin-bottom: 22px; flex-wrap: wrap; }
.tabs-row > :last-child:not(.tabs) { margin-bottom: 8px; }
.tabs { display: flex; gap: 22px; overflow: auto; }
.tab { background: none; border: 0; border-bottom: 2px solid transparent; padding: 10px 0; font-size: 12px; color: var(--muted); cursor: pointer; white-space: nowrap; }
.tab.active { color: var(--green); font-weight: 600; border-bottom-color: var(--green); }
</style>
