import { stageLabel } from '@/lib/dashboard'
import { STATUS_STAGES } from '@/lib/stageStatuses'

/**
 * The rules behind the Hiring → Labels panel (task.md: "the status label needs
 * an edit because our HR is used to her names").
 *
 * A *label* is editable; a *key* never changes once made. The key is what
 * `app.zoho_sub_status` and the Zoho status map join on, and what
 * `applications.sub_status_key` / `source_key` point at by foreign key, so
 * renaming a key would break the import; renaming a label is cosmetic and
 * safe. Since plan 068 an admin also adds statuses at any stage (the key is
 * made from the first name and kept) and retires them (`archived_at`) rather
 * than deleting what applications still point at. Pure shaping and
 * validation — RLS (`admin_write` on both lookups) decides who may write.
 */

/** Long enough for the longest shipped label with room to spare, short enough for a table cell. */
export const MAX_LABEL_LENGTH = 80

/** What `application_sub_statuses.key` accepts (0069's CHECK). */
export const KEY_PATTERN = /^[a-z][a-z0-9_]{1,39}$/
const KEY_MAX = 40
const KEY_FALLBACK = 'status'
const SORT_STEP = 10
/**
 * Named by the rules themselves — New's defaults and the "not responding"
 * count (0069) — so they may be renamed but never retired; 0088's
 * `application_sub_statuses_rule_keys_stay` CHECK says the same.
 */
const RULE_KEYS: ReadonlySet<string> = new Set(['applied', 'sourced', 'contact_attempted', 'contacted'])

export type LookupRow = { key: string; label: string; sort_order: number }
export type SubStatusRow = LookupRow & { stage_key: string; archived_at: string | null }
export type SubStatusGroup = { stageKey: string; stageLabel: string; rows: SubStatusRow[]; retired: SubStatusRow[] }

/** What gets stored: the trimmed text, so surrounding space never reaches the database. */
export function normaliseLabel(label: string): string {
  return label.trim()
}

/** The refusal to show, or null when the label may be saved. */
export function validateLabel(label: string): string | null {
  const next = normaliseLabel(label)
  if (!next) return 'A label cannot be empty.'
  if (next.length > MAX_LABEL_LENGTH) return `A label can be at most ${MAX_LABEL_LENGTH} characters.`
  return null
}

/** True only for an edit worth writing — surrounding space alone is not one. */
export function labelChanged(original: string, next: string): boolean {
  return normaliseLabel(original) !== normaliseLabel(next)
}

/** Pipeline order for the groups; an unknown stage sorts after the known ones rather than vanishing. */
function stageRank(stageKey: string): number {
  const i = (STATUS_STAGES as readonly string[]).indexOf(stageKey)
  return i >= 0 ? i : STATUS_STAGES.length
}

function bySortOrder(a: SubStatusRow, b: SubStatusRow): number {
  return a.sort_order - b.sort_order || a.key.localeCompare(b.key)
}

/**
 * Every stage, in pipeline order — an empty one too, so its first status can
 * be added — each with its live statuses in sort order and its retired ones
 * set aside for Restore. A stage the app does not know keeps its rows.
 */
export function groupByStage(rows: ReadonlyArray<SubStatusRow>): SubStatusGroup[] {
  const stages = [...new Set([...STATUS_STAGES, ...rows.map((r) => r.stage_key)])]
  return stages
    .sort((a, b) => stageRank(a) - stageRank(b) || a.localeCompare(b))
    .map((stageKey) => {
      const own = rows.filter((r) => r.stage_key === stageKey).sort(bySortOrder)
      return {
        stageKey,
        stageLabel: stageLabel(stageKey),
        rows: own.filter((r) => !r.archived_at),
        retired: own.filter((r) => Boolean(r.archived_at)),
      }
    })
}

function slug(label: string): string {
  return label
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
}

/**
 * The key a new status is stored under: its first name, lower-case, Latin
 * letters, digits and underscores, starting with a letter, at most forty
 * characters — and never one already taken, retired ones included, because
 * old applications and events still point at those. A name with nothing
 * Latin in it falls back to `status`.
 */
export function keyFromLabel(label: string, taken: ReadonlySet<string>): string {
  const raw = slug(label)
  // The CHECK wants a letter first and two characters at least: "X" is `status_x`.
  const lead = !raw ? KEY_FALLBACK : /^[a-z]/.test(raw) && raw.length >= 2 ? raw : `${KEY_FALLBACK}_${raw}`
  const base = lead.slice(0, KEY_MAX).replace(/_+$/, '')
  if (!taken.has(base)) return base
  for (let n = 2; ; n++) {
    const suffix = `_${n}`
    const candidate = `${base.slice(0, KEY_MAX - suffix.length).replace(/_+$/, '')}${suffix}`
    if (!taken.has(candidate)) return candidate
  }
}

function sameName(a: string, b: string): boolean {
  return normaliseLabel(a).toLowerCase() === normaliseLabel(b).toLowerCase()
}

/**
 * The refusal when a live status of the stage already reads `label` (the
 * database's unique index says the same, less kindly), or null. `exceptKey`
 * is the status being renamed; a retired status's name is free to reuse.
 */
export function duplicateLabel(label: string, stageRows: ReadonlyArray<SubStatusRow>, exceptKey?: string): string | null {
  const clash = stageRows.find((r) => !r.archived_at && r.key !== exceptKey && sameName(r.label, label))
  return clash ? `“${clash.label}” is already a status at this stage.` : null
}

/** False for the statuses the rules name; Retire is not offered for those. */
export function canRetire(key: string): boolean {
  return !RULE_KEYS.has(key)
}

/** A new status goes after everything at its stage, retired ones included. */
export function nextSortOrder(stageRows: ReadonlyArray<{ sort_order: number }>): number {
  return stageRows.reduce((max, r) => Math.max(max, r.sort_order), 0) + SORT_STEP
}
