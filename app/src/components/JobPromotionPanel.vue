<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { z } from 'zod'
import { supabase } from '@/lib/supabase'
import { useAuthStore } from '@/stores/auth'
import { friendlyRecruitmentError, promotionActions } from '@/lib/jobWorkspace'

/**
 * Recruitment marketing for one job (plan 017, blueprint §6). HR requests a
 * promotion with a snapshot of the public brief; Marketing drafts from that
 * brief only; a different person approves; a publisher records the URL.
 * Every move goes through advance_promotion (migration 0012), which enforces
 * the transition table and the separation of duties.
 */

type Brief = { title: string; company: string; summary: string; apply_url: string | null }

type Promotion = {
  id: string
  channel_key: string
  status: string
  brief: Brief
  copy: string | null
  publication_url: string | null
  deadline: string | null
  drafted_by: string | null
  requested_by_person: { full_name: string } | null
  reviewed_by_person: { full_name: string } | null
  published_by_person: { full_name: string } | null
}

const props = defineProps<{
  jobId: string
  companyId: string
  jobTitle: string
  companyName: string
  description: string
}>()
const emit = defineEmits<{ changed: [] }>()

const auth = useAuthStore()
const promotions = ref<Promotion[]>([])
const channelLabels = ref<Record<string, string>>({})
const loading = ref(true)
const error = ref<string | null>(null)
const busyId = ref<string | null>(null)
const drafts = ref<Record<string, string>>({})
const urls = ref<Record<string, string>>({})

const canRequest = computed(() => auth.can(props.companyId, 'jobs.edit'))
const can = (cap: string) => auth.can(props.companyId, cap)

const urlInput = z.string().trim().url("Enter the published post's address (https://…).")

function actionsFor(p: Promotion) {
  return promotionActions(p, auth.personId, can)
}

function isOwnDraftInReview(p: Promotion): boolean {
  return p.status === 'in_review' && p.drafted_by !== null && p.drafted_by === auth.personId
}

function badgeClass(status: string): string {
  if (status === 'published' || status === 'approved') return 'green'
  if (status === 'in_review') return 'amber'
  if (status === 'changes_requested') return 'blue'
  if (status === 'cancelled') return ''
  return 'blue'
}

function linkLabel(url: string): string {
  return url.replace(/^https?:\/\//i, '').replace(/\/$/, '')
}

async function load(): Promise<void> {
  loading.value = true
  error.value = null
  const [promoRes, channelsRes] = await Promise.all([
    supabase
      .from('promotions')
      .select(
        `id, channel_key, status, brief, copy, publication_url, deadline, drafted_by,
         requested_by_person:people!promotions_requested_by_fkey(full_name),
         reviewed_by_person:people!promotions_reviewed_by_fkey(full_name),
         published_by_person:people!promotions_published_by_fkey(full_name)`,
      )
      .eq('job_id', props.jobId)
      .order('created_at'),
    supabase.from('channels').select('key, label'),
  ])
  if (promoRes.error) {
    error.value = 'Could not load promotions. Check your access and connection.'
    console.error('Promotions load failed:', promoRes.error.message)
  }
  promotions.value = (promoRes.data ?? []) as Promotion[]
  channelLabels.value = Object.fromEntries((channelsRes.data ?? []).map((c) => [c.key, c.label]))
  drafts.value = Object.fromEntries(promotions.value.map((p) => [p.id, p.copy ?? '']))
  loading.value = false
}

/** The public brief is a snapshot: Marketing never reads the job row itself. */
function briefSnapshot(): Brief {
  return {
    title: props.jobTitle,
    company: props.companyName,
    summary: props.description.slice(0, 600),
    apply_url: null,
  }
}

const activePromotions = computed(() => promotions.value.filter((p) => p.status !== 'cancelled'))

/**
 * One promotion per channel: a fresh request inserts; a cancelled one is
 * requested again through the RPC, which resets it with a new brief.
 */
async function request(): Promise<void> {
  error.value = null
  const cancelled = promotions.value.find((p) => p.channel_key === 'linkedin' && p.status === 'cancelled')
  if (cancelled) return advance(cancelled, 'requested')
  busyId.value = 'new'
  const { error: err } = await supabase.from('promotions').insert({
    job_id: props.jobId,
    company_id: props.companyId,
    channel_key: 'linkedin',
    brief: briefSnapshot(),
    requested_by: auth.personId,
  })
  busyId.value = null
  if (err) {
    error.value = /promotions_job_id_channel_key_key/.test(err.message)
      ? 'A promotion for this channel already exists.'
      : friendlyRecruitmentError(err.message)
    return
  }
  await load()
  emit('changed')
}

async function advance(p: Promotion, to: string): Promise<void> {
  error.value = null
  let url: string | null = null
  if (to === 'published') {
    const parsed = urlInput.safeParse(urls.value[p.id] ?? '')
    if (!parsed.success) {
      error.value = parsed.error.issues[0]?.message ?? 'Check the address.'
      return
    }
    url = parsed.data
  }
  busyId.value = p.id
  const { error: err } = await supabase.rpc('advance_promotion', {
    p_promotion_id: p.id,
    p_to_status: to,
    p_copy: to === 'draft' || to === 'in_review' ? drafts.value[p.id] ?? '' : undefined,
    p_publication_url: url ?? undefined,
    p_brief: to === 'requested' ? briefSnapshot() : undefined,
  })
  busyId.value = null
  if (err) {
    error.value = friendlyRecruitmentError(err.message)
    return
  }
  await load()
  emit('changed')
}

onMounted(load)
</script>

<template>
  <div class="card">
    <div class="card-head">
      <div>
        <h2>Promotion</h2>
        <p>Marketing works from the approved public brief only — never from applications.</p>
      </div>
      <button
        v-if="canRequest && !activePromotions.length"
        class="button secondary"
        type="button"
        :disabled="busyId === 'new'"
        @click="request"
      >
        {{ promotions.length ? 'Request again' : 'Request promotion' }}
      </button>
    </div>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
    <div v-if="loading" class="empty">Loading promotions…</div>
    <div v-else-if="!promotions.length" class="empty">
      No promotion requested. Requesting one hands Marketing a brief with the job's public details.
    </div>
    <div v-else class="promotions">
      <div v-for="p in promotions" :key="p.id" class="promotion-card">
        <div class="promotion-head">
          <div>
            <strong>{{ channelLabels[p.channel_key] ?? p.channel_key }}</strong>
            <small>
              Requested by {{ p.requested_by_person?.full_name ?? '—' }}
              <template v-if="p.deadline"> · deadline {{ p.deadline }}</template>
              <template v-if="p.reviewed_by_person"> · reviewed by {{ p.reviewed_by_person.full_name }}</template>
              <template v-if="p.published_by_person"> · published by {{ p.published_by_person.full_name }}</template>
            </small>
          </div>
          <span class="badge" :class="badgeClass(p.status)">{{ p.status.replace('_', ' ') }}</span>
        </div>

        <div class="brief">
          <div class="eyebrow">Public brief</div>
          <strong>{{ p.brief.title }} · {{ p.brief.company }}</strong>
          <p>{{ p.brief.summary || 'No public summary yet — add a description to the job.' }}</p>
        </div>

        <div v-if="p.status === 'published' && p.publication_url" class="published">
          Published:
          <a :href="p.publication_url" target="_blank" rel="noopener">{{ linkLabel(p.publication_url) }}</a>
        </div>
        <template v-else-if="p.status !== 'cancelled'">
          <label class="copy-label" :for="`promo-copy-${p.id}`">Copy</label>
          <textarea
            :id="`promo-copy-${p.id}`"
            v-model="drafts[p.id]"
            rows="5"
            class="copy"
            :readonly="!can('marketing.draft') || !['requested', 'changes_requested', 'draft'].includes(p.status)"
            placeholder="Write the post from the public brief above…"
          ></textarea>
          <p v-if="isOwnDraftInReview(p)" class="inline-note">
            You drafted this, so you cannot review it — a different approver has to.
          </p>
          <div v-if="p.status === 'approved' && can('marketing.publish')" class="publish-form">
            <input
              :id="`promo-url-${p.id}`"
              v-model="urls[p.id]"
              inputmode="url"
              placeholder="https://… (the published post)"
              aria-label="Published post address"
            />
          </div>
        </template>

        <div class="actions">
          <button
            v-for="a in actionsFor(p)"
            :key="a.to"
            class="button small-btn"
            :class="{ secondary: a.to !== 'published' && a.to !== 'approved' }"
            type="button"
            :disabled="busyId === p.id"
            @click="advance(p, a.to)"
          >
            {{ a.label }}
          </button>
          <button
            v-if="canRequest && !['published', 'cancelled'].includes(p.status)"
            class="button secondary small-btn"
            type="button"
            :disabled="busyId === p.id"
            @click="advance(p, 'cancelled')"
          >
            Cancel promotion
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.promotions { display: grid; gap: 0; }
.promotion-card { padding: 18px 24px 20px; border-top: 1px solid #edf0eb; display: grid; gap: 12px; }
.promotion-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.promotion-head strong { display: block; font-size: 12px; font-weight: 550; }
.promotion-head small { display: block; font-size: 11px; color: var(--muted); margin-top: 4px; }
.brief { padding: 12px 14px; border-radius: 10px; background: #f6f8f4; }
.brief strong { display: block; font-size: 12px; margin-top: 6px; }
.brief p { margin: 6px 0 0; font-size: 11px; color: var(--muted); line-height: 1.6; white-space: pre-wrap; }
.copy-label { font-size: 11px; font-weight: 550; color: #566653; }
.copy {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 11px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
.copy[readonly] { background: #fafbf9; }
.inline-note { margin: 0; font-size: 11px; color: var(--amber); }
.publish-form input {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 9px 11px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
}
.published { font-size: 12px; }
.published a { color: var(--green); text-decoration: none; }
.published a:hover { text-decoration: underline; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
