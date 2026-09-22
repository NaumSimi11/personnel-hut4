<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { useDialogStore } from '@/stores/dialogs'
import { friendlyRecruitmentError } from '@/lib/jobWorkspace'
import { longDate } from '@/lib/candidatePool'
import {
  NOTES_PAGE_SIZE,
  addCandidateNote,
  canRemoveNote,
  listCandidateNotes,
  noteActor,
  noteKindLabel,
  removeCandidateNote,
  type CandidateNoteRow,
} from '@/lib/candidateNotes'

/**
 * Notes on the person (plan 055): the calls, messages and status changes
 * that were about the candidate and not about one job — imported Zoho
 * history and what a pool holder writes here. Newest first, fifty a page.
 * `canAdd` is a hint (the pool capability); add_candidate_note and the
 * candidate_notes policies decide.
 */

const props = withDefaults(defineProps<{ candidateId: string; canAdd: boolean; heading?: string }>(), {
  heading: 'Notes',
})

const auth = useAuthStore()
const dialogs = useDialogStore()
const notes = ref<CandidateNoteRow[]>([])
const loading = ref(true)
const loadingMore = ref(false)
const hasMore = ref(false)
const error = ref<string | null>(null)
const busy = ref(false)
const body = ref('')

const viewer = computed(() => ({ personId: auth.personId, isAdmin: auth.isAdmin }))

async function load(page: number): Promise<void> {
  if (page === 0) loading.value = true
  else loadingMore.value = true
  try {
    const rows = await listCandidateNotes(props.candidateId, page)
    notes.value = page === 0 ? rows : [...notes.value, ...rows]
    hasMore.value = rows.length === NOTES_PAGE_SIZE
  } catch (e) {
    error.value = 'Could not load notes. Check your access and connection.'
    console.error('Candidate notes load failed:', e instanceof Error ? e.message : e)
  } finally {
    loading.value = false
    loadingMore.value = false
  }
}

function loadMore(): void {
  void load(Math.floor(notes.value.length / NOTES_PAGE_SIZE))
}

async function add(): Promise<void> {
  error.value = null
  if (body.value.trim() === '') {
    error.value = 'Write the note first.'
    return
  }
  busy.value = true
  try {
    await addCandidateNote(props.candidateId, body.value)
    body.value = ''
    await load(0)
  } catch (e) {
    error.value = e instanceof Error ? friendlyRecruitmentError(e.message) : 'The note was not saved.'
  } finally {
    busy.value = false
  }
}

async function remove(n: CandidateNoteRow): Promise<void> {
  const ok = await dialogs.confirmAction({
    eyebrow: 'Notes',
    title: 'Remove this note?',
    hint: 'It leaves the record for good.',
    confirmLabel: 'Remove',
    danger: true,
  })
  if (!ok) return
  error.value = null
  busy.value = true
  try {
    await removeCandidateNote(n.id)
    await load(0)
  } catch (e) {
    error.value = e instanceof Error ? friendlyRecruitmentError(e.message) : 'Could not remove the note.'
  } finally {
    busy.value = false
  }
}

onMounted(() => load(0))
</script>

<template>
  <div class="card" data-testid="candidate-notes">
    <div class="card-head">
      <div>
        <h2>{{ heading }}</h2>
        <p>What happened with this person, across every job — newest first.</p>
      </div>
    </div>
    <form v-if="canAdd" class="add-form" @submit.prevent="add">
      <textarea
        id="note-body"
        v-model="body"
        rows="3"
        maxlength="4000"
        aria-label="Note"
        placeholder="What happened? Calls, messages, anything about the person — not about one job."
      ></textarea>
      <div class="actions">
        <button class="button small-btn" type="submit" :disabled="busy" data-testid="note-add">
          {{ busy ? 'Saving…' : 'Add note' }}
        </button>
      </div>
    </form>
    <p v-if="error" class="error-note" role="alert" style="margin: 16px 24px">{{ error }}</p>
    <div v-if="loading" class="empty">Loading notes…</div>
    <div v-else-if="!notes.length" class="empty">No notes yet.</div>
    <div v-else>
      <div v-for="n in notes" :key="n.id" class="note-row" :data-testid="`note-${n.id}`">
        <div class="note-head">
          <span class="badge" :class="n.kind === 'note' ? 'blue' : ''">{{ noteKindLabel(n.kind) }}</span>
          <small>{{ noteActor(n) }} · {{ longDate(n.occurred_at) }}</small>
          <button
            v-if="canRemoveNote(n, viewer)"
            class="button secondary small-btn"
            type="button"
            :disabled="busy"
            :data-testid="`note-remove-${n.id}`"
            @click="remove(n)"
          >
            Remove
          </button>
        </div>
        <p class="note-body">{{ n.body }}</p>
      </div>
      <div v-if="hasMore" class="more">
        <button class="button secondary small-btn" type="button" :disabled="loadingMore" data-testid="notes-show-more" @click="loadMore">
          {{ loadingMore ? 'Loading…' : 'Show more' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.add-form { padding: 14px 24px; border-top: 1px solid var(--line); background: #fafbf9; }
.add-form textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 9px 11px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
.actions { display: flex; justify-content: flex-end; margin-top: 8px; }
.note-row { padding: 13px 24px; border-top: 1px solid #edf0eb; }
.note-head { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.note-head small { flex: 1; font-size: 11px; color: var(--muted); }
.note-body { margin: 8px 0 0; font-size: 12px; line-height: 1.6; white-space: pre-wrap; overflow-wrap: anywhere; }
.more { padding: 12px 24px; border-top: 1px solid #edf0eb; text-align: center; }
.small-btn { font-size: 11px; padding: 7px 11px; }
</style>
