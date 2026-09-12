<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import {
  COMPANY_PROFILE_SELECT,
  DEFAULT_ACCENT,
  brandOf,
  companyInput,
  emptyCompanyForm,
  formFromCompany,
  friendlyCompanyError,
  rowFromForm,
  type CompanyBrand,
  type CompanyForm,
  type CompanyProfileRow,
} from '@/lib/companyForm'
import {
  LOGO_ACCEPT,
  logoPublicUrl,
  removeCompanyLogo,
  uploadCompanyLogo,
  validateLogoFile,
} from '@/lib/companyLogo'

/**
 * Create or edit a company's full profile — one page, three sections:
 * Identity & brand, Legal & registration, Contacts. Only name and short code
 * are required, so adding a company stays quick and the rest can follow.
 *
 * The logo is uploaded after the row exists (its object path is keyed by the
 * company id) and then recorded in brand.logo_path with a second update.
 * Authorization is the database's: RLS lets only platform admins write
 * companies and the logo bucket; this page just doesn't render for others.
 */

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const companyId = computed(() => (route.params.companyId as string | undefined) ?? null)
const isEdit = computed(() => companyId.value !== null)

const form = ref<CompanyForm>(emptyCompanyForm())
const existingBrand = ref<CompanyBrand>({})
const holdingId = ref<string | null>(null)
const people = ref<{ id: string; full_name: string }[]>([])

const logoFile = ref<File | null>(null)
const logoPreviewUrl = ref<string | null>(null)

const loading = ref(true)
const busy = ref(false)
const error = ref<string | null>(null)
const notFound = ref(false)

const accentSwatch = computed(() => form.value.accentColor || DEFAULT_ACCENT)
const codePreview = computed(() => form.value.shortCode.trim().toUpperCase() || '·')

function revokePreview(): void {
  if (logoPreviewUrl.value?.startsWith('blob:')) URL.revokeObjectURL(logoPreviewUrl.value)
}

function onLogoChange(event: Event): void {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0] ?? null
  error.value = null
  if (!file) return
  const problem = validateLogoFile(file)
  if (problem) {
    error.value = problem
    input.value = ''
    return
  }
  revokePreview()
  logoFile.value = file
  logoPreviewUrl.value = URL.createObjectURL(file)
}

function onAccentInput(event: Event): void {
  form.value = { ...form.value, accentColor: (event.target as HTMLInputElement).value }
}

function resetState(): void {
  revokePreview()
  form.value = emptyCompanyForm()
  existingBrand.value = {}
  logoFile.value = null
  logoPreviewUrl.value = null
  notFound.value = false
}

/**
 * Loads for the current route. Both /companies/new and /companies/:id/edit
 * render this component, so a route change reuses the instance — state is
 * reset here, not on mount. `error` is deliberately left alone: submit() owns
 * it, and a create-then-logo-failure hands its message across the redirect.
 */
async function load(): Promise<void> {
  loading.value = true
  resetState()

  const [holdingRes, peopleRes] = await Promise.all([
    supabase.from('companies').select('id').eq('kind', 'holding').is('archived_at', null).maybeSingle(),
    supabase.from('people').select('id, full_name').order('full_name'),
  ])
  holdingId.value = holdingRes.data?.id ?? null
  people.value = peopleRes.data ?? []
  if (peopleRes.error) console.error('Company form: people load failed:', peopleRes.error.message)

  if (companyId.value) {
    const { data, error: err } = await supabase
      .from('companies')
      .select(COMPANY_PROFILE_SELECT)
      .eq('id', companyId.value)
      .maybeSingle()
    if (err || !data) {
      notFound.value = true
      loading.value = false
      return
    }
    const row = data as CompanyProfileRow
    form.value = formFromCompany(row)
    existingBrand.value = brandOf(row)
    if (existingBrand.value.logo_path) logoPreviewUrl.value = logoPublicUrl(existingBrand.value.logo_path)
  }
  loading.value = false
}

async function submit(): Promise<void> {
  error.value = null
  const parsed = companyInput.safeParse(form.value)
  if (!parsed.success) {
    error.value = parsed.error.issues[0]?.message ?? 'Check the form.'
    return
  }
  busy.value = true
  let savedId: string | null = null
  try {
    const row = rowFromForm(parsed.data, existingBrand.value)
    savedId = isEdit.value ? await update(companyId.value!, row) : await create(row)
    if (logoFile.value) await attachLogo(savedId, logoFile.value)
    router.push({ name: 'company', params: { companyId: savedId } })
  } catch (e) {
    error.value = e instanceof Error ? friendlyCompanyError(e.message) : 'Could not save the company.'
    // The row exists but the logo didn't land: continue on the edit page for
    // that company so a retry can never create a duplicate.
    if (savedId && !isEdit.value) {
      router.replace({ name: 'company-edit', params: { companyId: savedId } })
    }
  } finally {
    busy.value = false
  }
}

type CompanyWrite = ReturnType<typeof rowFromForm>

async function create(row: CompanyWrite): Promise<string> {
  // Never create a second root: every new company hangs under the holding.
  if (!holdingId.value) throw new Error('The holding company could not be found, so nothing was created.')
  const { data, error: err } = await supabase
    .from('companies')
    .insert({ ...row, kind: 'company', parent_company_id: holdingId.value })
    .select('id')
    .single()
  if (err) throw new Error(err.message)
  return data.id
}

async function update(id: string, row: CompanyWrite): Promise<string> {
  // RLS doesn't raise on a refused UPDATE — it matches zero rows. maybeSingle
  // + a null check turns that silent no-op into a visible refusal.
  const { data, error: err } = await supabase
    .from('companies')
    .update(row)
    .eq('id', id)
    .select('id')
    .maybeSingle()
  if (err) throw new Error(err.message)
  if (!data) throw new Error('Nothing was saved — you may not have permission to change this company.')
  return data.id
}

async function attachLogo(id: string, file: File): Promise<void> {
  let path: string
  try {
    path = await uploadCompanyLogo(id, file)
  } catch (e) {
    const reason = e instanceof Error ? e.message : 'upload failed'
    throw new Error(`The company was saved, but the logo could not be uploaded: ${reason}`)
  }
  // Re-read brand so the update carries whatever the row already holds.
  const { data: current } = await supabase.from('companies').select('brand').eq('id', id).single()
  const previous = brandOf({ brand: current?.brand ?? {} })
  const { error: err } = await supabase
    .from('companies')
    .update({ brand: { ...previous, logo_path: path } })
    .eq('id', id)
  if (err) throw new Error(err.message)
  // Only now is the old object unreferenced.
  if (previous.logo_path && previous.logo_path !== path) await removeCompanyLogo(previous.logo_path)
}

onMounted(load)
onBeforeUnmount(revokePreview)

// new ↔ edit reuse this instance; reload for the new route.
watch(companyId, load)
</script>

<template>
  <div class="company-form-page">
    <router-link
      class="back-link"
      :to="isEdit && companyId ? { name: 'company', params: { companyId } } : { name: 'companies' }"
    >
      ← {{ isEdit ? 'Company profile' : 'Companies' }}
    </router-link>

    <p v-if="!auth.isAdmin" class="error-note" role="alert">Only platform admins can change companies.</p>
    <p v-else-if="notFound" class="error-note" role="alert">Company not found or not visible with your access.</p>
    <div v-else-if="loading" class="empty">Loading…</div>

    <form v-else novalidate @submit.prevent="submit">
      <div class="page-head">
        <div>
          <div class="eyebrow">{{ isEdit ? 'Company details' : 'The holding' }}</div>
          <h1>{{ isEdit ? 'Edit company.' : 'Add a company.' }}</h1>
          <p class="page-sub">
            Only the name and short code are required — everything else can be filled in later.
          </p>
        </div>
      </div>

      <section class="card">
        <div class="card-head">
          <div>
            <h2>Identity &amp; brand</h2>
            <p>How the company appears across the workspace and, later, on its careers page.</p>
          </div>
        </div>
        <div class="card-body">
          <div class="brand-row">
            <div class="logo-preview" :style="{ '--accent': accentSwatch }">
              <img v-if="logoPreviewUrl" :src="logoPreviewUrl" alt="" />
              <span v-else aria-hidden="true">{{ codePreview }}</span>
            </div>
            <div class="brand-fields">
              <div class="grid">
                <div class="field">
                  <label for="company-name">Company name</label>
                  <input id="company-name" v-model="form.name" required maxlength="120" />
                </div>
                <div class="field">
                  <label for="company-code">Short code</label>
                  <input
                    id="company-code"
                    v-model="form.shortCode"
                    class="code"
                    required
                    maxlength="6"
                    autocapitalize="characters"
                    spellcheck="false"
                  />
                  <small class="field-hint">2–6 letters or digits. Shown as the tile when there is no logo.</small>
                </div>
              </div>
              <div class="field">
                <label for="company-tagline">Tagline</label>
                <input id="company-tagline" v-model="form.tagline" maxlength="160" placeholder="One line on what the company does" />
              </div>
              <div class="grid">
                <div class="field">
                  <label for="company-website">Website</label>
                  <input id="company-website" v-model="form.website" inputmode="url" placeholder="company.example" />
                </div>
                <div class="field">
                  <label for="company-accent">Accent colour</label>
                  <div class="accent-row">
                    <input
                      id="company-accent"
                      type="color"
                      :value="accentSwatch"
                      aria-describedby="company-accent-hint"
                      @input="onAccentInput"
                    />
                    <input
                      class="accent-hex"
                      v-model="form.accentColor"
                      maxlength="7"
                      placeholder="#2f5d4f"
                      spellcheck="false"
                      aria-label="Accent colour hex"
                    />
                  </div>
                  <small id="company-accent-hint" class="field-hint">Tints the company's tile and banner.</small>
                </div>
              </div>
              <div class="field">
                <label for="company-logo">Logo</label>
                <input id="company-logo" type="file" :accept="LOGO_ACCEPT" @change="onLogoChange" />
                <small class="field-hint">PNG, JPEG, WebP or SVG, up to 1 MB. Square works best.</small>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section class="card">
        <div class="card-head">
          <div>
            <h2>Legal &amp; registration</h2>
            <p>What contracts, offer letters and payroll exports need.</p>
          </div>
        </div>
        <div class="card-body">
          <div class="grid three">
            <div class="field">
              <label for="company-legal-name">Legal name</label>
              <input id="company-legal-name" v-model="form.legalName" maxlength="200" placeholder="If different from the display name" />
            </div>
            <div class="field">
              <label for="company-registration">Registration number</label>
              <input id="company-registration" v-model="form.registrationNumber" maxlength="60" />
            </div>
            <div class="field">
              <label for="company-tax-id">VAT / tax ID</label>
              <input id="company-tax-id" v-model="form.taxId" maxlength="60" />
            </div>
          </div>
          <div class="field">
            <label for="company-address1">Registered address</label>
            <input id="company-address1" v-model="form.addressLine1" maxlength="200" placeholder="Street and number" />
          </div>
          <div class="field">
            <label for="company-address2" class="visually-hidden">Address line 2</label>
            <input id="company-address2" v-model="form.addressLine2" maxlength="200" placeholder="Floor, suite, building (optional)" />
          </div>
          <div class="grid three">
            <div class="field">
              <label for="company-city">City</label>
              <input id="company-city" v-model="form.city" maxlength="100" />
            </div>
            <div class="field">
              <label for="company-postcode">Postcode</label>
              <input id="company-postcode" v-model="form.postcode" maxlength="20" />
            </div>
            <div class="field">
              <label for="company-country">Country</label>
              <input id="company-country" v-model="form.country" maxlength="100" />
            </div>
          </div>
        </div>
      </section>

      <section class="card">
        <div class="card-head">
          <div>
            <h2>Leave</h2>
            <p>The country decides which statutory holidays apply; the defaults seed every new leave year.</p>
          </div>
        </div>
        <div class="card-body">
          <div class="grid three">
            <div class="field">
              <label for="company-country-code">Country code</label>
              <input id="company-country-code" v-model="form.countryCode" maxlength="2" placeholder="MK" />
            </div>
            <div class="field">
              <label for="company-leave-days">Yearly leave entitlement (days)</label>
              <input id="company-leave-days" v-model="form.leaveEntitlementDays" inputmode="decimal" />
            </div>
            <div class="field">
              <label for="company-carry-over">Carry-over usable until (MM-DD)</label>
              <input id="company-carry-over" v-model="form.leaveCarryOverUntil" maxlength="5" placeholder="06-30" />
            </div>
          </div>
        </div>
      </section>

      <section class="card">
        <div class="card-head">
          <div>
            <h2>Contacts</h2>
            <p>The director and HR contact are people in the workspace; access is granted separately.</p>
          </div>
        </div>
        <div class="card-body">
          <div class="grid">
            <div class="field">
              <label for="company-director">Director</label>
              <select id="company-director" v-model="form.directorPersonId">
                <option value="">Not set</option>
                <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
              </select>
            </div>
            <div class="field">
              <label for="company-hr-contact">HR contact</label>
              <select id="company-hr-contact" v-model="form.hrContactPersonId">
                <option value="">Not set</option>
                <option v-for="p in people" :key="p.id" :value="p.id">{{ p.full_name }}</option>
              </select>
            </div>
            <div class="field">
              <label for="company-email">Contact email</label>
              <input id="company-email" v-model="form.contactEmail" type="email" maxlength="320" />
            </div>
            <div class="field">
              <label for="company-phone">Phone</label>
              <input id="company-phone" v-model="form.contactPhone" type="tel" maxlength="40" />
            </div>
          </div>
        </div>
      </section>

      <p v-if="error" class="error-note" role="alert">{{ error }}</p>

      <div class="actions">
        <router-link
          class="button secondary"
          :to="isEdit && companyId ? { name: 'company', params: { companyId } } : { name: 'companies' }"
        >
          Cancel
        </router-link>
        <button class="button" type="submit" :disabled="busy">
          <template v-if="isEdit">{{ busy ? 'Saving…' : 'Save changes' }}</template>
          <template v-else>{{ busy ? 'Creating…' : 'Create company' }}</template>
        </button>
      </div>
    </form>
  </div>
</template>

<style scoped>
.company-form-page { max-width: 860px; }
.back-link {
  display: inline-block;
  font-size: 11px;
  color: var(--muted);
  text-decoration: none;
  margin-bottom: 16px;
}
.back-link:hover { color: var(--green); }
.page-head { margin-bottom: 22px; }
.page-sub { margin: 0; font-size: 12px; color: var(--muted); }
.card { margin-bottom: 18px; }
.card-head h2 { margin: 0; }
.brand-row { display: flex; gap: 24px; align-items: flex-start; }
.brand-fields { flex: 1; min-width: 0; }
.logo-preview {
  --accent: #2f5d4f;
  display: grid;
  place-items: center;
  width: 96px;
  height: 96px;
  flex-shrink: 0;
  border-radius: 18px;
  background: color-mix(in srgb, var(--accent) 14%, white);
  color: var(--accent);
  font-size: 22px;
  font-weight: 700;
  letter-spacing: 0.02em;
  overflow: hidden;
}
.logo-preview img { width: 100%; height: 100%; object-fit: contain; padding: 10px; box-sizing: border-box; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 16px; }
.grid.three { grid-template-columns: 1fr 1fr 1fr; }
@media (max-width: 640px) {
  .brand-row { flex-direction: column; }
  .grid, .grid.three { grid-template-columns: 1fr; }
}
.code { text-transform: uppercase; letter-spacing: 0.08em; }
.field-hint { display: block; font-size: 10px; color: var(--muted); margin-top: -2px; }
.accent-row { display: flex; gap: 8px; align-items: center; }
.accent-row input[type='color'] {
  width: 42px;
  height: 38px;
  padding: 3px;
  flex-shrink: 0;
  cursor: pointer;
}
.accent-hex { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.field input[type='file'] { padding: 8px 10px; font-size: 11px; }
.visually-hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip: rect(0 0 0 0);
  white-space: nowrap;
}
.actions { display: flex; gap: 9px; justify-content: flex-end; margin-top: 6px; }
.actions .button { text-decoration: none; }
</style>
