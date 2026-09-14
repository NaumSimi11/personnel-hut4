import { ref, computed } from 'vue'
import { defineStore } from 'pinia'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'

export const useAuthStore = defineStore('auth', () => {
  const session = ref<Session | null>(null)
  const personName = ref<string | null>(null)
  const personId = ref<string | null>(null)
  const isAdmin = ref(false)
  // Own grants, company → capability keys. Only a UI hint for showing
  // actions: RLS and the RPCs re-check every capability server-side.
  const capabilities = ref<Record<string, ReadonlySet<string>>>({})
  const ready = ref(false)
  const avatarPath = ref<string | null>(null)

  const isAuthenticated = computed(() => session.value !== null)
  // Set at invite/reset time via the admin API; cleared only by the
  // change-password endpoint. RLS refuses everything while this is true.
  const mustChangePassword = computed(
    () => session.value?.user.app_metadata?.must_change_password === true,
  )

  async function init(): Promise<void> {
    if (ready.value) return
    const { data } = await supabase.auth.getSession()
    session.value = data.session
    supabase.auth.onAuthStateChange((_event, next) => {
      session.value = next
      if (!next) personName.value = null
    })
    if (session.value) await loadPerson()
    ready.value = true
  }

  async function loadPerson(): Promise<void> {
    if (!session.value) return
    const { data, error } = await supabase
      .from('people')
      .select('id, full_name, avatar_url')
      .eq('user_id', session.value.user.id)
      .maybeSingle()
    if (error) {
      console.error('Failed to load person record:', error.message)
      return
    }
    personName.value = data?.full_name ?? null
    personId.value = data?.id ?? null
    avatarPath.value = data?.avatar_url ?? null
    if (!personId.value) {
      isAdmin.value = false
      capabilities.value = {}
      return
    }
    const [adminRes, grantsRes] = await Promise.all([
      supabase.from('platform_admins').select('person_id').eq('person_id', personId.value).maybeSingle(),
      supabase
        .from('access_grants')
        .select('company_id, grant_capabilities(capability_key)')
        .eq('person_id', personId.value),
    ])
    isAdmin.value = adminRes.data !== null
    if (grantsRes.error) console.error('Failed to load own grants:', grantsRes.error.message)
    capabilities.value = Object.fromEntries(
      (grantsRes.data ?? []).map((g) => [
        g.company_id,
        new Set(g.grant_capabilities.map((c) => c.capability_key)),
      ]),
    )
  }

  /** May the signed-in person do `capability` in `companyId`? Admins may do everything. */
  function can(companyId: string, capability: string): boolean {
    return isAdmin.value || (capabilities.value[companyId]?.has(capability) ?? false)
  }

  /** ...in any company — the gate for holding-wide panels (the dashboard's pipeline, the Hiring tabs). */
  function canAnywhere(capability: string): boolean {
    return isAdmin.value || Object.values(capabilities.value).some((caps) => caps.has(capability))
  }

  /** Pull fresh JWT claims (e.g. after the must-change flag is cleared). */
  async function refresh(): Promise<void> {
    const { data } = await supabase.auth.refreshSession()
    session.value = data.session
    await loadPerson()
  }

  async function signIn(email: string, password: string): Promise<void> {
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw new Error(friendlyAuthError(error.message))
    await loadPerson()
  }

  async function signOut(): Promise<void> {
    await supabase.auth.signOut()
    personName.value = null
    personId.value = null
    isAdmin.value = false
    capabilities.value = {}
  }

  function friendlyAuthError(message: string): string {
    if (/invalid login credentials/i.test(message)) {
      return 'That email and password combination is not right.'
    }
    return message
  }

  return {
    session,
    personName,
    avatarPath,
    personId,
    isAdmin,
    capabilities,
    can,
    canAnywhere,
    ready,
    isAuthenticated,
    mustChangePassword,
    init,
    signIn,
    signOut,
    refresh,
  }
})
