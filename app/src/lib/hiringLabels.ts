import { PIPELINE_STAGES, stageLabel } from '@/lib/dashboard'

/**
 * The rules behind the Hiring → Labels panel (task.md: "the status label needs
 * an edit because our HR is used to her names").
 *
 * Only the *label* is editable. The `key` is what `app.zoho_sub_status` and the
 * Zoho status map join on, and what `applications.source_key` points at by
 * foreign key, so renaming a key would break the import; renaming a label is
 * cosmetic and safe. Pure shaping and validation — RLS (`admin_write` on both
 * lookups) decides who may actually write.
 */

/** Long enough for the longest shipped label with room to spare, short enough for a table cell. */
export const MAX_LABEL_LENGTH = 80

export type LookupRow = { key: string; label: string; sort_order: number }
export type SubStatusRow = LookupRow & { stage_key: string }
export type SubStatusGroup = { stageKey: string; stageLabel: string; rows: SubStatusRow[] }

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
  const i = PIPELINE_STAGES.findIndex((s) => s.key === stageKey)
  if (i >= 0) return i
  return stageKey === 'withdrawn' ? PIPELINE_STAGES.length : PIPELINE_STAGES.length + 1
}

/** Sub-statuses grouped under their stage, groups in pipeline order and rows in sort order. */
export function groupByStage(rows: ReadonlyArray<SubStatusRow>): SubStatusGroup[] {
  const byStage = new Map<string, SubStatusRow[]>()
  for (const row of rows) {
    byStage.set(row.stage_key, [...(byStage.get(row.stage_key) ?? []), row])
  }
  return [...byStage.entries()]
    .sort(([a], [b]) => stageRank(a) - stageRank(b) || a.localeCompare(b))
    .map(([stageKey, group]) => ({
      stageKey,
      stageLabel: stageLabel(stageKey),
      rows: [...group].sort((a, b) => a.sort_order - b.sort_order || a.key.localeCompare(b.key)),
    }))
}
